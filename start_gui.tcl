set scriptDir [file dirname [info script]]
source [file join $scriptDir hm_material_assign.tcl]
hm_mat_assign::gui
