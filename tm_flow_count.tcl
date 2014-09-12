::cisco::eem::event_register_timer watchdog time 2.5 maxrun 1.9

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*

array set flow_savedata [list]

#
# Flows in cache
#

# fetch all previous data
if { [catch {context_retrieve "DDOSDET2" "flow_savedata"} result] } {
    array set oldsavedata [list]
} else {
    array set oldsavedata $result
}

# fetch flows in cache
array set snmp_res [sys_reqinfo_snmp oid 1.3.6.1.4.1.9.9.97.1.4.1.1.5 get_type next]

if {$_cerrno != 0} {
   set result [format "component=%s; subsys err=%s; posix err=%s;\n%s" \
   $_cerr_sub_num $_cerr_sub_err $_cerr_posix_err $_cerr_str]
   action_syslog priority warning msg $result
   error $result
}

#set array with data
set flowcount(count) $snmp_res(value)

if { ![string match "1.3.6.1.4.1.9.9.97.1.4.1.1.5.*" $snmp_res(oid)] } {
    # read wrong SNMP object 
    set flow_savedata(flowcount) $oldsavedata(flowcount)
    set flow_savedata(flowcreations) $oldsavedata(flowcreations)
    set flow_savedata(inter) $oldsavedata(inter)
    catch { context_save DDOSDET2 flow_savedata }
    action_syslog priority warning msg "SNMP returned wrong OID!"
} else {

    # A sort of hack to prevent issues with weird SNMP behaviour.
    # This is used to test SNMP does not return the previous OID again.
    # We use GETNEXT so that shouldnt happen ...
    set old_oid "false"
    
    # This loop is used to query the information for all available modules
    while {[string match "1.3.6.1.4.1.9.9.97.1.4.1.1.5.*" $snmp_res(oid)] && ![string equal $old_oid $snmp_res(oid)]} {
#        action_syslog msg "Flow cache entries: $snmp_res(oid) : $snmp_res(value)"
        set flowcount(count) [expr { $flowcount(count) + $snmp_res(value)}]
        set old_oid $snmp_res(oid)
        array set snmp_res [sys_reqinfo_snmp oid $snmp_res(oid) get_type next]
    }

    #save array
    set flow_savedata(flowcount) $flowcount(count)

    # calculate the difference
    if {[info exists oldsavedata(flowcount)]} {

        # initialize some variables, either from memory or if not available from constants
        if {[info exists oldsavedata(flowcreations)]} {
            set flowcreations $oldsavedata(flowcreations)
        } else {
            set flowcreations 0
        }
        if {[info exists oldsavedata(inter)]} {
            set inter $oldsavedata(inter)
        } else {
            set inter 0
        }
        
        # the actual difference
        set diff [expr {$flowcount(count) - $oldsavedata(flowcount)}]
        
        # Branch based on the sign
        if {[expr {$diff > 0}]} {
            # If its positive, we can just use it
            set flow_savedata(flowcreations) [expr {$flowcreations + $diff}]
            set flow_savedata(inter) [expr {0.65 * $inter + 0.35 * $diff}]
        } else {
            # If its negative, a lot of flows have been exported, and to counter this we use an
            # inter-/extrapolated value
            set flow_savedata(inter) $inter
            set flow_savedata(flowcreations) [expr {$flowcreations + $inter}]
        }
        
    } else {
        set flow_savedata(flowcreations) $flowcount(count)
        set flow_savedata(inter) 0
    }

    # save actual save data
    catch { context_save DDOSDET2 flow_savedata }
}

