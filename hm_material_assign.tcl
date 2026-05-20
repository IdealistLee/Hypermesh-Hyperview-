# HyperMesh 2019 / Abaqus material and property assignment helper.
#
# Usage in HyperMesh Tcl console:
#   source C:/path/to/hm_material_assign.tcl
#   hm_mat_assign::run C:/path/to/component_material.csv C:/path/to/materials.csv
#
# CSV formats:
#   component_material.csv: component_name,material_name
#   materials.csv: material_name,abaqus_inp_material_block
#
# If the Abaqus material block contains commas or line breaks, quote the whole
# second CSV field. Use \n inside the cell when your editor cannot store
# multi-line quoted fields.

namespace eval hm_mat_assign {
    variable VERSION "1.0.0"
    variable SHELL_CONFIGS {103 104 106 108 111 112}
    variable SOLID_CONFIGS {204 205 206 208 210 213}
    variable IMPORT_READER "#abaqus/abaqus"
    variable gui
    array set gui {
        componentCsv ""
        materialCsv ""
        status "Ready"
        running 0
    }
}

proc hm_mat_assign::trim {value} {
    return [string trim $value " \t\r\n"]
}

proc hm_mat_assign::normalize_newlines {value} {
    regsub -all {\\r\\n|\\n|\\r} $value "\n" value
    return $value
}

proc hm_mat_assign::csv_record_complete {text} {
    set inQuote 0
    set len [string length $text]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $text $i]
        if {$ch eq "\""} {
            if {$inQuote && $i + 1 < $len && [string index $text [expr {$i + 1}]] eq "\""} {
                incr i
            } else {
                set inQuote [expr {!$inQuote}]
            }
        }
    }
    return [expr {!$inQuote}]
}

proc hm_mat_assign::parse_csv_record {record} {
    set fields {}
    set field ""
    set inQuote 0
    set len [string length $record]

    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $record $i]
        if {$ch eq "\""} {
            if {$inQuote && $i + 1 < $len && [string index $record [expr {$i + 1}]] eq "\""} {
                append field "\""
                incr i
            } else {
                set inQuote [expr {!$inQuote}]
            }
        } elseif {$ch eq "," && !$inQuote} {
            lappend fields [trim $field]
            set field ""
        } else {
            append field $ch
        }
    }

    lappend fields [trim $field]
    return $fields
}

proc hm_mat_assign::read_csv {path minFields} {
    if {![file exists $path]} {
        error "CSV file not found: $path"
    }

    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set rows {}
    set record ""
    set lineNo 0

    while {[gets $fh line] >= 0} {
        incr lineNo
        if {$record eq ""} {
            set record $line
        } else {
            append record "\n" $line
        }

        if {![csv_record_complete $record]} {
            continue
        }

        set trimmed [trim $record]
        if {$trimmed ne "" && ![string match "#*" $trimmed]} {
            set fields [parse_csv_record $record]
            if {[llength $fields] < $minFields} {
                close $fh
                error "CSV parse error in $path line $lineNo: expected at least $minFields fields"
            }
            lappend rows $fields
        }
        set record ""
    }
    close $fh

    if {$record ne ""} {
        error "CSV parse error in $path: unterminated quoted field"
    }
    return $rows
}

proc hm_mat_assign::maybe_skip_header {rows firstNames secondNames} {
    if {[llength $rows] == 0} {
        return $rows
    }
    set first [string tolower [trim [lindex [lindex $rows 0] 0]]]
    set second [string tolower [trim [lindex [lindex $rows 0] 1]]]
    if {[lsearch -exact $firstNames $first] >= 0 && [lsearch -exact $secondNames $second] >= 0} {
        return [lrange $rows 1 end]
    }
    return $rows
}

proc hm_mat_assign::read_component_map {path} {
    set rows [maybe_skip_header [read_csv $path 2] \
        {component comp part part_name component_name 部件 组件} \
        {material mat material_name 材料}]

    set result [dict create]
    foreach row $rows {
        set comp [normalize_component_name [lindex $row 0]]
        set mat [trim [lindex $row 1]]
        if {$comp eq "" || $mat eq ""} {
            continue
        }
        dict set result $comp $mat
        dict set result [string tolower $comp] $mat
    }
    return $result
}

proc hm_mat_assign::read_material_blocks {path} {
    set rows [maybe_skip_header [read_csv $path 2] \
        {material mat material_name 材料} \
        {inp abaqus_inp material_block 材料卡片}]

    set result [dict create]
    foreach row $rows {
        set mat [trim [lindex $row 0]]
        set block [normalize_newlines [trim [lindex $row 1]]]
        if {$mat eq "" || $block eq ""} {
            continue
        }
        if {![regexp -nocase {^\s*\*material\s*,} $block]} {
            set block "*Material, name=$mat\n$block"
        }
        dict set result $mat $block
    }
    return $result
}

proc hm_mat_assign::safe_name {name} {
    set cleaned [string trim $name]
    regsub -all {["'*?$]} $cleaned "_" cleaned
    if {[string length $cleaned] > 80} {
        set cleaned [string range $cleaned 0 79]
    }
    return $cleaned
}

proc hm_mat_assign::normalize_component_name {name} {
    set cleaned [trim $name]
    regsub -all {@+$} $cleaned "" cleaned
    if {[regexp {^(.+)@([^@]+)$} $cleaned -> base suffix]} {
        set cleaned $base
        regsub -all {@+$} $cleaned "" cleaned
    }
    return [trim $cleaned]
}

proc hm_mat_assign::dict_get_component_material {componentMap componentName} {
    set key [normalize_component_name $componentName]
    if {[dict exists $componentMap $key]} {
        return [list 1 $key [dict get $componentMap $key]]
    }
    set lowerKey [string tolower $key]
    if {[dict exists $componentMap $lowerKey]} {
        return [list 1 $key [dict get $componentMap $lowerKey]]
    }
    return [list 0 $key ""]
}

proc hm_mat_assign::error_message {err opts} {
    if {$err ne "" && $err ne "0"} {
        return $err
    }
    if {[dict exists $opts -errorinfo]} {
        set info [dict get $opts -errorinfo]
        if {$info ne "" && $info ne "0"} {
            return $info
        }
    }
    return "HyperMesh command returned error code/message: $err"
}

proc hm_mat_assign::entity_exists_by_name {entityType name} {
    if {[catch {hm_entityinfo exist $entityType $name -byname} exists]} {
        return 0
    }
    return $exists
}

proc hm_mat_assign::entity_id_by_name {entityType name} {
    if {[catch {hm_getvalue $entityType name=$name dataname=id} id] || $id eq ""} {
        if {[catch {hm_getentityvalue $entityType $name id 0 -byname} id]} {
            return ""
        }
    }
    return $id
}

proc hm_mat_assign::entity_name_by_id {entityType id} {
    if {[catch {hm_getvalue $entityType id=$id dataname=name} name] || $name eq ""} {
        set name [hm_entityinfo name $entityType $id]
    }
    return $name
}

proc hm_mat_assign::all_component_ids {} {
    *createmark comps 1 all
    return [hm_getmark comps 1]
}

proc hm_mat_assign::component_elem_ids {compId} {
    *createmark elems 1 "by comp id" $compId
    return [hm_getmark elems 1]
}

proc hm_mat_assign::list_contains {items value} {
    return [expr {[lsearch -exact $items $value] >= 0}]
}

proc hm_mat_assign::component_mesh_kind {compId} {
    variable SHELL_CONFIGS
    variable SOLID_CONFIGS

    set hasShell 0
    set hasSolid 0
    if {![catch {hm_getconfigtypeincol comps $compId} configTypes]} {
        foreach {config type} $configTypes {
            if {[list_contains $SHELL_CONFIGS $config]} {
                set hasShell 1
            }
            if {[list_contains $SOLID_CONFIGS $config]} {
                set hasSolid 1
            }
        }
    }

    if {!$hasShell && !$hasSolid} {
        foreach elemId [component_elem_ids $compId] {
            if {[catch {hm_getvalue elems id=$elemId dataname=config} config]} {
                continue
            }
            if {[list_contains $SHELL_CONFIGS $config]} {
                set hasShell 1
            }
            if {[list_contains $SOLID_CONFIGS $config]} {
                set hasSolid 1
            }
        }
    }

    if {$hasShell && $hasSolid} {
        return "mixed"
    }
    if {$hasSolid} {
        return "solid"
    }
    if {$hasShell} {
        return "shell"
    }
    return "unknown"
}

proc hm_mat_assign::write_material_import_file {materialNames materialBlocks outPath} {
    set fh [open $outPath w]
    fconfigure $fh -encoding utf-8
    puts $fh "** Generated by hm_material_assign.tcl"
    foreach matName $materialNames {
        if {![dict exists $materialBlocks $matName]} {
            close $fh
            error "Material '$matName' is referenced by component map but missing in material CSV"
        }
        puts $fh [dict get $materialBlocks $matName]
        puts $fh ""
    }
    close $fh
}

proc hm_mat_assign::import_materials_from_inp {inpPath} {
    variable IMPORT_READER

    set options {
        "ASSEMS_SKIP "
        "BEAMSECTCOLS_SKIP "
        "BEAMSECTS_SKIP "
        "BLOCKS_SKIP "
        "COMPONENTS_SKIP "
        "CONNECTORS_SKIP "
        "CONTACTSURFS_SKIP "
        "CONTROLCARDS_SKIP "
        "CONTROLVOLS_SKIP "
        "CURVES_SKIP "
        "ELEMS_SKIP "
        "EQUATIONS_SKIP "
        "GROUPS_SKIP "
        "LOADCOLS_SKIP "
        "LOADS_SKIP "
        "LOADSTEPS_SKIP "
        "NODES_SKIP "
        "OUTPUTBLOCKS_SKIP "
        "PLOTS_SKIP "
        "PROPERTIES_SKIP "
        "SETS_SKIP "
        "SYSTCOLS_SKIP "
        "SYSTEMS_SKIP "
        "TAGS_SKIP "
        "TITLES_SKIP "
        "VECTORS_SKIP "
    }

    set createStringArrayCmd [list *createstringarray [llength $options]]
    foreach option $options {
        lappend createStringArrayCmd $option
    }
    eval $createStringArrayCmd
    *feinputwithdata2 $IMPORT_READER $inpPath 0 0 0 0 0 1 [llength $options] 1 0
}

proc hm_mat_assign::ensure_materials {materialNames materialBlocks workDir} {
    set missing {}
    foreach matName $materialNames {
        if {![entity_exists_by_name mats $matName]} {
            lappend missing $matName
        }
    }

    if {[llength $missing] > 0} {
        set importPath [file normalize [file join $workDir "__hm_mat_assign_materials.inp"]]
        write_material_import_file $missing $materialBlocks $importPath
        import_materials_from_inp $importPath
    }

    set materialIds [dict create]
    foreach matName $materialNames {
        set matId [entity_id_by_name mats $matName]
        if {$matId eq ""} {
            error "Material '$matName' was not found after import"
        }
        dict set materialIds $matName $matId
    }
    return $materialIds
}

proc hm_mat_assign::rename_component {oldName newName} {
    if {$oldName eq $newName} {
        return $newName
    }
    set finalName $newName
    if {[entity_exists_by_name comps $finalName]} {
        set finalName [hm_getincrementalname comps $finalName]
    }
    *renamecollector component $oldName $finalName
    return $finalName
}

proc hm_mat_assign::set_property_material {propId matId} {
    set errors {}
    if {[catch {*setvalue props id=$propId materialid=$matId} err]} {
        lappend errors $err
    } else {
        return
    }
    if {[catch {*setvalue props id=$propId materialid="{mats $matId}"} err]} {
        lappend errors $err
    } else {
        return
    }
    error "failed to set property material: [join $errors {; }]"
}

proc hm_mat_assign::set_component_material {compId matId} {
    set errors {}
    if {[catch {*setvalue comps id=$compId materialid=$matId} err]} {
        lappend errors $err
    } else {
        return
    }
    if {[catch {*setvalue comps id=$compId materialid="{mats $matId}"} err]} {
        lappend errors $err
    } else {
        return
    }
    error "failed to set component material: [join $errors {; }]"
}

proc hm_mat_assign::set_component_property {compId propId} {
    set errors {}
    if {[catch {*setvalue comps id=$compId propertyid="{props $propId}"} err]} {
        lappend errors $err
    } else {
        return
    }
    if {[catch {*setvalue comps id=$compId propertyid=$propId} err]} {
        lappend errors $err
    } else {
        return
    }
    error "failed to set component property: [join $errors {; }]"
}

proc hm_mat_assign::set_component_elements_property {compId propId} {
    set elemIds [component_elem_ids $compId]
    if {[llength $elemIds] == 0} {
        return
    }

    *createmark elems 1 "by comp id" $compId
    set errors {}
    if {[catch {*setvalue elems mark=1 propertyid="{props $propId}"} err]} {
        lappend errors $err
    } else {
        return
    }
    if {[catch {*setvalue elems mark=1 propertyid=$propId} err]} {
        lappend errors $err
    } else {
        return
    }
    error "failed to set element property: [join $errors {; }]"
}

proc hm_mat_assign::ensure_property {propName meshKind matId} {
    set propName [safe_name $propName]
    if {[entity_exists_by_name props $propName]} {
        set propId [entity_id_by_name props $propName]
    } else {
        *createentity props name=$propName
        if {[catch {hm_latestentityid props} propId] || $propId eq ""} {
            *createmark props 1 -1
            set propId [lindex [hm_getmark props 1] 0]
        }
        if {$propId eq ""} {
            error "Failed to create property '$propName'"
        }
    }

    if {$meshKind eq "solid"} {
        set cardImage "SOLIDSECTION"
    } elseif {$meshKind eq "shell"} {
        set cardImage "SHELLSECTION"
    } else {
        error "Unsupported mesh kind '$meshKind' for property '$propName'"
    }

    *setvalue props id=$propId cardimage=$cardImage
    set_property_material $propId $matId
    return $propId
}

proc hm_mat_assign::assign_property_to_component {compId propId matId} {
    set_property_material $propId $matId
    set_component_property $compId $propId
    set_component_material $compId $matId
    set_component_elements_property $compId $propId
}

proc hm_mat_assign::show_only_unassigned_components {} {
    *displaycollector components none "" 1 1
    foreach compId [all_component_ids] {
        set propId ""
        if {[catch {hm_getvalue comps id=$compId dataname=property.id} propId]} {
            catch {set propId [hm_getentityvalue comps $compId propertyid 0]}
        }
        if {$propId eq "" || $propId == 0} {
            set compName [entity_name_by_id comps $compId]
            *displaycollector components on $compName 1 1
        }
    }
}

proc hm_mat_assign::unique_material_names {componentMap} {
    set names {}
    dict for {compName matName} $componentMap {
        if {[lsearch -exact $names $matName] < 0} {
            lappend names $matName
        }
    }
    return $names
}

proc hm_mat_assign::stats_text {stats {componentCsv ""} {materialCsv ""}} {
    set lines {}
    lappend lines "Run completed."
    if {$componentCsv ne ""} {
        lappend lines "Component map: $componentCsv"
    }
    if {$materialCsv ne ""} {
        lappend lines "Material CSV:  $materialCsv"
    }
    lappend lines ""
    lappend lines "Processed components: [dict get $stats processed]"
    lappend lines "Renamed components:   [dict get $stats renamed]"
    lappend lines "Assigned properties:  [dict get $stats assigned]"
    lappend lines "Linked prop/material: [dict get $stats propMaterialLinked]"
    lappend lines "Linked comp/property: [dict get $stats compPropertyLinked]"
    lappend lines "Skipped components:   [dict get $stats skipped]"
    lappend lines "Unmapped components:  [llength [dict get $stats unmapped]]"
    lappend lines ""
    lappend lines "Only components without property definition are displayed now."

    set unmapped [dict get $stats unmapped]
    if {[llength $unmapped] > 0} {
        lappend lines ""
        lappend lines "Components not found in component-material CSV:"
        foreach name $unmapped {
            lappend lines "  - $name"
        }
    }

    set errors [dict get $stats errors]
    if {[llength $errors] > 0} {
        lappend lines ""
        lappend lines "Warnings / errors:"
        foreach msg $errors {
            lappend lines "  - $msg"
        }
    }
    return [join $lines "\n"]
}

proc hm_mat_assign::print_stats {stats} {
    puts "hm_material_assign completed."
    puts "  processed: [dict get $stats processed]"
    puts "  renamed:   [dict get $stats renamed]"
    puts "  assigned:  [dict get $stats assigned]"
    puts "  prop/mat:  [dict get $stats propMaterialLinked]"
    puts "  comp/prop: [dict get $stats compPropertyLinked]"
    puts "  skipped:   [dict get $stats skipped]"
    puts "  unmapped:  [llength [dict get $stats unmapped]]"
    if {[llength [dict get $stats unmapped]] > 0} {
        puts "  unmapped components:"
        foreach name [dict get $stats unmapped] {
            puts "    - $name"
        }
    }
    if {[llength [dict get $stats errors]] > 0} {
        puts "  errors:"
        foreach msg [dict get $stats errors] {
            puts "    - $msg"
        }
    }
}

proc hm_mat_assign::run {{componentCsv ""} {materialCsv ""}} {
    if {$componentCsv eq ""} {
        set componentCsv [tk_getOpenFile -title "Select component-material CSV" -filetypes {{"CSV files" {.csv}} {"All files" {*}}}]
    }
    if {$materialCsv eq ""} {
        set materialCsv [tk_getOpenFile -title "Select material definition CSV" -filetypes {{"CSV files" {.csv}} {"All files" {*}}}]
    }
    if {$componentCsv eq "" || $materialCsv eq ""} {
        error "Both CSV files are required"
    }

    set componentCsv [file normalize $componentCsv]
    set materialCsv [file normalize $materialCsv]
    set workDir [file dirname $materialCsv]
    set componentMap [read_component_map $componentCsv]
    set materialBlocks [read_material_blocks $materialCsv]
    set materialNames [unique_material_names $componentMap]
    set materialIds [ensure_materials $materialNames $materialBlocks $workDir]

    set stats [dict create processed 0 renamed 0 assigned 0 propMaterialLinked 0 compPropertyLinked 0 skipped 0 unmapped {} errors {}]
    foreach compId [all_component_ids] {
        if {[catch {set oldName [entity_name_by_id comps $compId]} err opts]} {
            dict lappend stats errors "component id $compId: [error_message $err $opts]"
            dict incr stats skipped
            continue
        }

        lassign [dict_get_component_material $componentMap $oldName] mapped lookupName matName
        if {!$mapped} {
            dict lappend stats unmapped $oldName
            dict incr stats skipped
            continue
        }

        if {[catch {set meshKind [component_mesh_kind $compId]} err opts]} {
            dict lappend stats errors "$oldName: mesh type check failed: [error_message $err $opts]"
            dict incr stats skipped
            continue
        }
        if {$meshKind eq "mixed" || $meshKind eq "unknown"} {
            dict lappend stats errors "$oldName: mesh type is $meshKind; property not assigned"
            dict incr stats skipped
            continue
        }

        if {[catch {
            set matId [dict get $materialIds $matName]
            set targetName [safe_name "${lookupName}@${matName}"]
            set finalName [rename_component $oldName $targetName]
            set propId [ensure_property $finalName $meshKind $matId]
            assign_property_to_component $compId $propId $matId
        } err opts]} {
            dict lappend stats errors "$oldName: [error_message $err $opts]"
            dict incr stats skipped
            continue
        }

        if {$finalName ne $oldName} {
            dict incr stats renamed
        }
        dict incr stats processed
        dict incr stats assigned
        dict incr stats propMaterialLinked
        dict incr stats compPropertyLinked
    }

    if {[catch {show_only_unassigned_components} displayErr displayOpts]} {
        dict lappend stats errors "Display filter failed: [error_message $displayErr $displayOpts]"
    }

    print_stats $stats
    return $stats
}

proc hm_mat_assign::browse_file {field title} {
    variable gui
    set path [tk_getOpenFile -parent .hmMatAssign -title $title -filetypes {{"CSV files" {.csv}} {"All files" {*}}}]
    if {$path ne ""} {
        set gui($field) [file normalize $path]
    }
}

proc hm_mat_assign::raise_gui {} {
    set win .hmMatAssign
    if {[winfo exists $win]} {
        catch {wm attributes $win -topmost 1}
        raise $win
        focus $win
    }
}

proc hm_mat_assign::set_output {message} {
    set textWidget .hmMatAssign.body.output
    if {[winfo exists $textWidget]} {
        $textWidget configure -state normal
        $textWidget delete 1.0 end
        $textWidget insert end $message
        $textWidget configure -state disabled
    }
}

proc hm_mat_assign::run_from_gui {} {
    variable gui
    if {$gui(running)} {
        return
    }

    set componentCsv [trim $gui(componentCsv)]
    set materialCsv [trim $gui(materialCsv)]
    if {$componentCsv eq "" || $materialCsv eq ""} {
        tk_messageBox -parent .hmMatAssign -icon warning -type ok -title "Missing CSV" -message "Please select both CSV files."
        raise_gui
        return
    }

    set gui(running) 1
    set gui(status) "Running..."
    set_output "Running, please wait..."
    update idletasks

    if {[catch {
        set stats [run $componentCsv $materialCsv]
    } err opts]} {
        set gui(status) "Failed"
        set message [error_message $err $opts]
        set_output "Run failed.\n\n$message"
        tk_messageBox -parent .hmMatAssign -icon error -type ok -title "Material assignment failed" -message $message
        raise_gui
    } else {
        set gui(status) "Completed"
        set message [stats_text $stats $componentCsv $materialCsv]
        set_output $message
        tk_messageBox -parent .hmMatAssign -icon info -type ok -title "Material assignment completed" -message $message
        raise_gui
    }

    set gui(running) 0
}

proc hm_mat_assign::gui {} {
    variable gui

    if {[catch {package require Tk}]} {
        error "Tk is not available in this HyperMesh session."
    }

    set win .hmMatAssign
    if {[winfo exists $win]} {
        raise $win
        focus $win
        return
    }

    toplevel $win
    wm title $win "HyperMesh Material Assign"
    wm minsize $win 680 430
    catch {wm attributes $win -topmost 1}

    frame $win.body -padx 12 -pady 12
    grid $win.body -row 0 -column 0 -sticky nsew
    grid rowconfigure $win 0 -weight 1
    grid columnconfigure $win 0 -weight 1
    grid columnconfigure $win.body 1 -weight 1
    grid rowconfigure $win.body 4 -weight 1

    label $win.body.title -text "HyperMesh Material Assign" -font {Arial 12 bold}
    grid $win.body.title -row 0 -column 0 -columnspan 3 -sticky w -pady {0 10}

    label $win.body.compLabel -text "Component map CSV"
    entry $win.body.compEntry -textvariable ::hm_mat_assign::gui(componentCsv)
    button $win.body.compBrowse -text "Browse..." -command {hm_mat_assign::browse_file componentCsv "Select component-material CSV"}
    grid $win.body.compLabel -row 1 -column 0 -sticky w -padx {0 8} -pady 4
    grid $win.body.compEntry -row 1 -column 1 -sticky ew -pady 4
    grid $win.body.compBrowse -row 1 -column 2 -sticky ew -padx {8 0} -pady 4

    label $win.body.matLabel -text "Material definition CSV"
    entry $win.body.matEntry -textvariable ::hm_mat_assign::gui(materialCsv)
    button $win.body.matBrowse -text "Browse..." -command {hm_mat_assign::browse_file materialCsv "Select material definition CSV"}
    grid $win.body.matLabel -row 2 -column 0 -sticky w -padx {0 8} -pady 4
    grid $win.body.matEntry -row 2 -column 1 -sticky ew -pady 4
    grid $win.body.matBrowse -row 2 -column 2 -sticky ew -padx {8 0} -pady 4

    frame $win.body.actions
    button $win.body.actions.run -text "Run" -width 12 -command {hm_mat_assign::run_from_gui}
    button $win.body.actions.close -text "Close" -width 12 -command {destroy .hmMatAssign}
    label $win.body.actions.status -textvariable ::hm_mat_assign::gui(status)
    pack $win.body.actions.run -side left
    pack $win.body.actions.close -side left -padx 8
    pack $win.body.actions.status -side left -padx 16
    grid $win.body.actions -row 3 -column 0 -columnspan 3 -sticky w -pady {10 8}

    text $win.body.output -height 12 -wrap word -state disabled
    scrollbar $win.body.scroll -orient vertical -command "$win.body.output yview"
    $win.body.output configure -yscrollcommand "$win.body.scroll set"
    grid $win.body.output -row 4 -column 0 -columnspan 2 -sticky nsew
    grid $win.body.scroll -row 4 -column 2 -sticky ns

    set_output "Select the component-material CSV and material definition CSV, then click Run."
}

proc hmma {{componentCsv ""} {materialCsv ""}} {
    if {$componentCsv eq "" && $materialCsv eq ""} {
        return [::hm_mat_assign::gui]
    }
    return [::hm_mat_assign::run $componentCsv $materialCsv]
}
