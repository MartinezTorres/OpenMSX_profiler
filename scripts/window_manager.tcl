

namespace eval wm {

    if ![info exists Status] { variable Status [dict create] }
    if ![info exists Configuration] { variable Configuration [dict create] }

    proc start {} {

        if {[dict exists $::wm::Status widgets wm]} return
        if {[dict size $::wm::Status]==0} { set ::wm::Status [::wm::defaults::Status] } 
        if {[dict size $::wm::Configuration]==0} { set ::wm::Configuration [::wm::defaults::Configuration] } 
        
        dict set ::wm::Status widgets wm {}
        osd create rectangle "wm" -relw 1 -relh 1 -rgba 0x00000000 -clip true
                
        after "20" ::wm::callbacks::upkeep
        after "mouse button1 down" ::wm::callbacks::on_mouse_button1_down
        after "mouse button1 up" ::wm::callbacks::on_mouse_button1_up
        after "mouse motion" ::wm::callbacks::on_mouse_motion
    }

    proc stop {} {
        
        dict unset ::wm::Status widgets wm
    }

    proc reload_configuration {} {
    }
    
    proc widget {command absolute_path args} {
        
        ::wm::start
        if {$absolute_path=={}} { error "absolute_path can not be empty."}
        
        set previousPath $widget_methods::base_path 
        set widget_methods::base_path $absolute_path
        
        if {[namespace which widget_methods::${command}] == {}} {
            error "Unknown widget command: \"$command\""
        }

        set ret [widget_methods::${command} {*}$args]

        set widget_methods::base_path $previousPath
        
        return $ret
    }
    
    namespace eval widget_methods {
        
        variable base_path {}
        
        # Returns the absolute path. 
        # Key value "parent" actually moves up a level.
        proc get_absolute_path { base_path {relative_path {}} } {
            
            if {$relative_path != {}} {             
                set absolute_path $base_path.$relative_path
            } else {
                set absolute_path $base_path
            }
            
            #puts stderr $absolute_path
            while {[regsub {\.[^\.]*\.parent} $absolute_path {} absolute_path]} {}
            #puts stderr $absolute_path
            return $absolute_path
        }
        
        # Shortcut: returns the absolute path w.r.t. the current widget's path.
        proc p { {relative_path {}} } { return [get_absolute_path $::wm::widget_methods::base_path $relative_path] }

        # Returns value of the argument pointed by the relative id
        proc rexists {relative_path} {

            set absolute_path [p $relative_path]
            return [dict exists $::wm::Status widgets $absolute_path]
        }

        proc rget {relative_path} {
            
            set absolute_path [p $relative_path]
            set ret {}
            catch { set ret [dict get $::wm::Status widgets $absolute_path] }
            return $ret
        }


        proc rset {args} {
            
            foreach {relative_path value} $args {
                set absolute_path [p $relative_path]
                dict set ::wm::Status widgets $absolute_path $value
                dict set ::wm::Status to_update $absolute_path {}
                if {[dict exists $::wm::Status widgets $absolute_path.on_set]} {
                    regexp {^(.*)\.([^\.]*)$} $absolute_path match parent parameter
                    ::wm::widget execute_callback $parent $parameter.on_set
                }
            }
        }

        proc runset {args} {
            
            foreach relative_path $args {
                set absolute_path [p $relative_path]
                if {[dict exists $::wm::Status widgets $absolute_path]} {
                    dict unset ::wm::Status widgets $absolute_path
                    dict unset ::wm::Status to_update $absolute_path
                }
            }
        }

        proc request_update {args} {
            
            if {$args=={}} {
                set absolute_path [p]
                foreach child_absolute_path [dict keys [dict get $::wm::Status widgets $absolute_path.*]] {
                    dict set ::wm::Status to_update $child_absolute_path {}
                }
                dict set ::wm::Status to_update $absolute_path {}
            } else {                    
                foreach relative_path $args {
                    set absolute_path [p $relative_path]  
                    dict set ::wm::Status to_update $absolute_path {}
                }
            }
        }
        
        proc execute_osd_update {parameter value} {
            
            puts stderr "update! [p] $parameter [rget $parameter] $value"

            dict with ::wm::Configuration {}
            set absolute_path [p]
            osd configure $absolute_path -$parameter [subst $value]                    
            dict unset ::wm::Status to_update $absolute_path.osd_$parameter
        }
        
        proc execute_callback {callback_id args} {
            
            if {[rexists $callback_id]} {
                dict with ::wm::Configuration {}
                eval [rget $callback_id]
            }
        }

        proc execute_target {parameter} {

            #puts stderr "target! [p]  $parameter [rget $parameter] [rget $parameter.target]"
            
            dict with ::wm::Configuration {}
            set current [subst [rget $parameter]]
            set target [subst [rget $parameter.target]]
            if {[expr {abs($current-$target)}]>1} { 
                rset $parameter [expr {$smoothness*$current+(1-$smoothness)*$target}]
            } else {
                rset $parameter [rget $parameter.target]
                runset $parameter.target
            }
        }


        proc add {widget_type args} {
            
            ::wm::start
            
            if { [rexists {}]} { error "Adding an already existing widget" }
            if {![rexists parent]} { error "Adding an orfan widget: [p] [p parent]" }

            rset inner_type $widget_type

            if {[namespace which $widget_type] != {}} {
                
                $widget_type [p] {*}$args
                
            } elseif {[namespace which ::wm::widgets::$widget_type] != {}} {
                
                ::wm::widgets::$widget_type [p] {*}$args
                
            } elseif {$widget_type=="text"} {
                
                osd create text [p]
                rset {} {} {*}$args
                
            } elseif {$widget_type=="rectangle"} {

                osd create rectangle [p]
                rset {} {} {*}$args
            
            } else {
                error "Requested an unknown widget type"
            }

            if {![rexists {}]} { error "Widget not created" }
            
            rset outer_type $widget_type
            
            ::wm::widget execute_callback [p parent] on_added_child [string range [p] [expr {[string length [p parent]]+1}] end ]
        }

        proc remove {} {

            execute_callback on_pre_remove
            
            set absolute_path [p]
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.[^\.]*$} $child_absolute_path match parent]} {
                    if {$parent == $absolute_path} {
                        ::wm::widget remove $child_absolute_path
                    }
                }
            }

            execute_callback on_post_remove
            
            if {[osd exists $absolute_path]} { osd destroy $absolute_path }
            runset $absolute_path
        }
        
        proc rebase {old_path} {
            
            set old_path [get_absolute_path $new_path]
            set new_path [p]

            ::wm::widget execute_callback $old_path on_pre_rebase $new_path
            
            if { [rexists {}]} { error "Rebasing into an already existing widget" }
            if {![rexists parent]} { error "Rebasing into an orfan widget" }
            
            rset {} [dict get $::wm::Status widgets $old_path]
            if {[osd exists $old_path]} { 
                osd create [::wm::widget rexists $old_path inner_type] $new_path
            }
        
            foreach child_absolute_path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.([^\.]*)$} $child_absolute_path match parent children]} {
                    if {$parent == $old_path} {
                        ::wm::widget rebase "$old_path.$children" "$new_path.$children" 
                    }
                }
            }

            execute_callback on_post_rebase $old_path

            if {[osd exists $old_path]} { osd destroy $old_path }
            dict unset ::wm::Status widgets $old_path
        }
    }

    namespace eval widgets {
                
        proc dock {path args} {
            ::wm::widget add $path rectangle
            ::wm::widget add $path.panel rectangle
            ::wm::widget add $path.title rectangle 
            ::wm::widget add $path.title.text text      
            ::wm::widget add $path.hide toggle_button 

            ::wm::widget rset $path \
                first_window {} \
                last_window {} \
                osd_x {[expr {-10*$sz}]} \
                osd_x.target 0 \
                osd_y {[expr {4*$sz}]} \
                osd_w {[expr {$sz*$width}]} \
                osd_relh 1 \
                osd_clip true \
                osd_rgba 0x00000040 \
                window_list [dict create] \
                title.osd_x 0 \
                title.osd_y 0 \
                title.osd_w {[expr {($width-1)*$sz}]} \
                title.osd_h {[expr {1*$sz}]} \
                title.osd_rgba {0xFFFFFF40} \
                title.text.osd_text "Dock" \
                title.text.osd_font {$font_sans} \
                title.text.osd_x {[expr {1.5*$sz/6.}]} \
                title.text.osd_y {[expr {0.25*$sz/6.}]} \
                title.text.osd_size {[expr {5*$sz/6}]} \
                title.text.osd_rgba {0xFFFFFFFF} \
                panel.on_added_child {
                    lassign $args child
                    if {[rget $child.outer_type]=="window"} {
                        if {[rget parent.first_window]=={}} {
                            rset parent.first_window $child
                        } else {
                            rset $child.prev_window [rget parent.last_window]
                            rset [rget parent.last_window].next_window $child
                        }
                        rset parent.last_window $child
                    }
                } \
                panel.osd_x 0 \
                panel.osd_y {[expr {1*$sz}]} \
                panel.osd_w {[expr {($width)*$sz}]} \
                panel.osd_relh 1 \
                panel.osd_clip true \
                panel.osd_rgba {0x00000040} \
                hide.textOn  "\u25BA" \
                hide.textOff "\u25C4" \
                hide.on_On  { rset parent.osd_x.target {[expr {-($width-1)*$sz}]} } \
                hide.on_Off { rset parent.osd_x.target 0 } \
                hide.osd_relx 1 \
                hide.osd_w {[expr {-1*$sz}]} \
                hide.osd_h {[expr {1*$sz}]} \
                hide.text.osd_x {[expr {1.5*$sz/6.-$sz}]} \
                hide.text.osd_y {[expr {-0.25*$sz/6.}]} \
                hide.text.osd_size {[expr {5*$sz/6}]} \
                hide.text.osd_font {$font_mono} \
                {*}$args

        }

        proc window {path args} {
            
            ::wm::widget add $path rectangle
            ::wm::widget add $path.panel rectangle
            ::wm::widget add $path.title rectangle 
            ::wm::widget add $path.title.text text      
            ::wm::widget add $path.hide toggle_button 

            ::wm::widget rset $path \
                osd_x 0 \
                osd_y 0 \
                osd_y.on_set {
                    if {[rexists next_window]} {
                        puts stderr "Why? [p] rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]"
                        rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]
                    }
                } \
                osd_w {[expr {$sz*$width}]} \
                osd_h {[expr {1*$sz}]} \
                osd_h.target {[expr {2*$sz+[subst [rget panel.osd_h]]}]} \
                osd_h.on_set {
                    if {[rexists next_window]} {
                        puts stderr "osd_h? [p] rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]"
                        rset parent.[rget next_window].osd_y [expr {[subst [rget osd_y]]+[subst [rget osd_h]]}]
                    }
                } \
                osd_clip true \
                osd_rgba 0x00000040 \
                title.osd_x 0 \
                title.osd_y 0 \
                title.osd_w {[expr {($width-0.9)*$sz}]} \
                title.osd_h {[expr {1*$sz}]} \
                title.osd_bordersize {[expr {0.1*$sz}]} \
                title.osd_borderrgba {0x404040FF} \
                title.osd_rgba {0x808080FF} \
                title.text.osd_text "Dock" \
                title.text.osd_font {$font_sans} \
                title.text.osd_x {[expr {1.5*$sz/6.}]} \
                title.text.osd_y {[expr {0.25*$sz/6.}]} \
                title.text.osd_size {[expr {5*$sz/6}]} \
                title.text.osd_rgba {0x404040FF} \
                panel.osd_x 0 \
                panel.osd_y {[expr {1*$sz}]} \
                panel.osd_w {[expr {($width-1)*$sz}]} \
                panel.osd_h {[expr {5*$sz}]} \
                panel.osd_clip true \
                panel.osd_rgba {0x40404040} \
                hide.textOn  "\u25BC" \
                hide.textOff "\u25B2" \
                hide.on_On  { puts stderr "asdf"; ::wm::widget rset [p parent] osd_h.target {[expr {1*$sz}]} } \
                hide.on_Off { puts stderr "asdf"; ::wm::widget rset [p parent] osd_h.target {[expr {2*$sz+[subst [rget panel.osd_h]]}]} } \
                hide.osd_relx 1 \
                hide.osd_w {[expr {-1*$sz}]} \
                hide.osd_h {[expr {1*$sz}]} \
                hide.text.osd_x {[expr {1.5*$sz/6.-$sz}]} \
                hide.text.osd_y {[expr {-0.25*$sz/6.}]} \
                hide.text.osd_size {[expr {5*$sz/6}]} \
                hide.text.osd_font {$font_mono} \
                {*}$args
        }

        proc toggle_button {path args} {
            
            ::wm::widget add $path button 
            
            ::wm::widget rset $path \
                is_toggled 0 \
                textOn "On" \
                textOff "Off" \
                on_On {} \
                on_Off {} \
                on_activation { 
                    if {[rget is_toggled]} {
                        rset is_toggled 0
                        puts stderr off[rget on_Off]
                        eval [rget on_Off]
                    } else {
                        rset is_toggled 1
                        puts stderr On[rget on_On]
                        eval [rget on_On]
                    }
                    request_update text.osd_text
                } \
                text.osd_text {[expr {[rget parent.is_toggled]?[rget parent.textOn]:[rget parent.textOff]}]} \
                {*}$args
        }

        proc button {path args} {

            ::wm::widget add $path rectangle  
            ::wm::widget add $path.text text 
            
            ::wm::widget rset $path \
                osd_w {[expr {4*$sz}]} \
                osd_h {[expr {1*$sz}]} \
                osd_bordersize {[expr {0.1*$sz}]} \
                osd_borderrgba {0x404040FF} \
                osd_rgba {0x808080FF} \
                text.osd_text "Button" \
                text.osd_font {$font_sans} \
                text.osd_x {[expr {1.5*$sz/6.}]} \
                text.osd_y {[expr {0.25*$sz/6.}]} \
                text.osd_size {[expr {5*$sz/6}]} \
                text.osd_rgba {0x404040FF} \
                is_clickable {} \
                on_mouse_button1_down { rset osd_rgba 0xC0C0C0FF } \
                on_mouse_button1_up   { rset osd_rgba 0x808080FF } \
                {*}$args
            
        }
    }


    namespace eval callbacks {

        proc upkeep {} {

            if {![dict exists $::wm::Status widgets wm]} { return }
            
            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.on_upkeep$} $path match parent]} {
                    ::wm::widget execute_callback $parent on_upkeep
                }

                if {[regexp {^(.*)\.([^\.]*)\.target$} $path match parent parameter]} {
                    ::wm::widget execute_target $parent $parameter
                }
            }
            
            foreach global_path [dict keys [dict get $::wm::Status to_update]] {
                if {[regexp {^(.*)\.osd_([^\.]*)$} $global_path global_path osd_id parameter]} {
                    ::wm::widget execute_osd_update $osd_id $parameter [dict get $::wm::Status widgets $global_path]
                }
            }
            
            after "20" ::wm::callbacks::upkeep
            return
        }

        proc on_mouse_button1_down {} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.is_clickable$} $path match parent]} {
                    if {[is_mouse_over $parent]==1} {
                        ::wm::widget rset $parent is_pressed {}
                        ::wm::widget execute_callback $parent on_mouse_button1_down
                    }                                        
                }
            }
            after "mouse button1 down" ::wm::callbacks::on_mouse_button1_down
        }

        proc on_mouse_button1_up {} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }
            

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.is_clickable$} $path match parent]} {

                    if {[::wm::widget rexists $parent is_pressed]} {
                        if {[is_mouse_over $parent]} {
                            ::wm::widget execute_callback $parent on_activation
                        }
                        ::wm::widget execute_callback $parent on_mouse_button1_up
                        ::wm::widget runset $parent is_pressed
                    }
                }
            }
            after "mouse button1 up" ::wm::callbacks::on_mouse_button1_up
        }

        proc on_mouse_motion {} {
            
            if {![dict exists $::wm::Status widgets wm]} { return }

            foreach path [dict keys [dict get $::wm::Status widgets]] {
                if {[regexp {^(.*)\.is_clickable$} $path match parent]} {
                    if {[is_mouse_over $parent]==1} {
                        ::wm::widget execute_callback $parent on_mouse_motion
                    }
                }
            }
            after "mouse motion" ::wm::callbacks::on_mouse_motion
        }

        proc is_mouse_over {id} {
            
            set ret 0
            if {[osd exists $id]} {
                catch {
                    lassign [osd info $id -mousecoord] x y
                    if {($x >= 0) && ($x <= 1) && ($y >= 0) && ($y <= 1)} {
                        set ret 1
                    }
                }
            }
            return $ret
        }
    }


    namespace eval defaults {

        proc Status {} { return [dict create \
            widgets [dict create] \
        ]}

        proc Configuration {} { return [dict create \
            font_mono "skins/DejaVuSansMono.ttf" \
            font_sans "skins/DejaVuSans.ttf" \
            sz 24 \
            width 25 \
            smoothness 0.8 \
        ]}
    }
}
