::cisco::eem::event_register_timer watchdog time 10 maxrun 9

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*

# this should be the same as the watchdog time interval
set timeinterval 10

# variable for determining decay of old interpolation values
set inter_alpha 0.15

# The length of a season in the seasonality modelling. We have chosen 24 hours.
set season_length [ expr { round( 86400.0 /  $timeinterval )} ]

# To decrease the amount of memory utilization, we only store one seasonality value per hour, and interpolate in between.
set season_rate [ expr { round( 3600.0 /  $timeinterval ) } ]
set num_season_parts [ expr { round( $season_length /  $season_rate ) } ]

# These values determine the rate at which previous values are discared for the season and base components respectively.
set gamma 0.4
set alpha [expr { 2.0 / ( (5400.0 / $timeinterval) + 1 ) } ]

# The threshold multiplier for the thresold determining the maximum 'normal' measurement value
set c_threshold 4.0

# A "deadzone" to determine the minimum size of a anomaly.
set M_min 7000.0

# The CUSUM threshold multiplier
set c_cusum 6.0

set day [clock format [clock seconds] -format %w]

# check if its a weekday or weekend
if { [expr {$day > 0 && $day < 6}] } {
    set day_type weekday
} elseif { [expr {$day == 0 || $day == 6}] } {
    set day_type weekend
} else {
    error "Unknown day, cannot determine weekend <--> weekday"
}

set hour [clock format [clock seconds] -format %H]


# Define a square root implementation, as our TCL version in IOS did not implement one
proc sqrt {n} {
    set oldguess -1.0
    set guess 1.0
    while { [expr { abs($guess - $oldguess) > 0.5 }] } {
        set oldguess $guess
        set guess [expr { ($guess + ($n / $guess)) / 2.0}]
    }
    return $guess
}


array set savedata [list]

##########################
# Flows in cache
##########################

# fetch all previous data
if { [catch {context_retrieve "DDOSDET" "savedata"} result] } {
    array set oldsavedata [list]
} else {
    array set oldsavedata $result
}

#load season data
if { [catch {context_retrieve "DDOSDET_seasons" "s_savedata"} result] } {
    array set s_savedata [list]
} else {
    array set s_savedata $result
}

# retrieve data from other script
if { [catch {context_retrieve "DDOSDET2" "flow_savedata"} result] } {
    array set flow_savedata [list]
} else {
    array set flow_savedata $result
}

# set the difference (i.e. copy data read from the other script)
# and clean it, if read successfully. 
if {[info exists flow_savedata(flowcreations)]} {
    set diff_numflowscache $flow_savedata(flowcreations)
    set flow_savedata(flowcreations) 0
    set savedata(flowcount_timestamp) [clock seconds]
} else {
    set diff_numflowscache 0
    set savedata(flowcount_timestamp) $oldsavedata(flowcount_timestamp)
}

# measure time difference since last measurement.
if {[info exists oldsavedata(flowcount_timestamp)]} {
    set diff_numflowscache_time [expr {[clock seconds] - $oldsavedata(flowcount_timestamp)}]
    if {[expr {$diff_numflowscache_time < $timeinterval}]} {
        set diff_numflowscache_time $timeinterval
    }
} else {
    set diff_numflowscache_time $timeinterval
}

#save data back into context
catch { context_save DDOSDET2 flow_savedata }

#############################
# Number of exported packets
#############################

array set snmp_res [sys_reqinfo_snmp oid 1.3.6.1.4.1.9.9.387.1.4.3 get_type next]

#store in array
set exportedcount(count) $snmp_res(value)
set exportedcount(timestamp) [clock seconds]

# Make sure the returned SNMP object has the correct ID. Sometimes it appears
# to return a wrong object...
if { [string match "1.3.6.1.4.1.9.9.387.1.4.3.*" $snmp_res(oid)] } {
    # save array
    set savedata(exportedcount_count) $exportedcount(count)
    set savedata(exportedcount_timestamp) $exportedcount(timestamp)
} else {
    # save old data, as we didnt fetch something new
    set savedata(exportedcount_count) $oldsavedata(exportedcount_count)
    set savedata(exportedcount_timestamp) $oldsavedata(exportedcount_timestamp)
    set exportedcount(count) $oldsavedata(exportedcount_count)
    set exportedcount(timestamp) $oldsavedata(exportedcount_timestamp)
}

#calculate differences
if {[info exists oldsavedata(exportedcount_count)]} {
    set diff_exportedcount [expr {$exportedcount(count) - $oldsavedata(exportedcount_count)}]
} else {
    set diff_exportedcount 0
}

# Calculate time differences
if {[info exists oldsavedata(exportedcount_timestamp)]} {
    set diff_exportedcount_time [expr {$exportedcount(timestamp) - $oldsavedata(exportedcount_timestamp)}]
    if {[expr {$diff_exportedcount_time < $timeinterval}]} {
        set diff_exportedcount_time $timeinterval
    }
} else {
    set diff_exportedcount_time $timeinterval
}

##############################
# Learn Failures
##############################

#fetch learn failures
array set snmp_res [sys_reqinfo_snmp oid 1.3.6.1.4.1.9.9.97.1.4.1.1.6 get_type next]

#set array with data
set failurecount(count) $snmp_res(value)
set failurecount(timestamp) [clock seconds]

if { [string match "1.3.6.1.4.1.9.9.97.1.4.1.1.6.*" $snmp_res(oid)] } {
    
    # again a sort of "hack" to prevent problems with weird SNMP behaviour in which
    # the same OID would be returned using the GET NEXT method.
    set old_oid "false"
    
    # This loop is used to query the Flow learn failures for different modules in the switch
    while {[string match "1.3.6.1.4.1.9.9.97.1.4.1.1.6.*" $snmp_res(oid)] && ![string equal $old_oid $snmp_res(oid)]} {
#        action_syslog msg "Flow Learn Failures: $snmp_res(oid) : $snmp_res(value)"
        set failurecount(count) [expr { $failurecount(count) + $snmp_res(value)}]
        set old_oid $snmp_res(oid)
        array set snmp_res [sys_reqinfo_snmp oid $snmp_res(oid) get_type next]
    }

    #save array
    set savedata(failurecount_count) $failurecount(count)
    set savedata(failurecount_timestamp) $failurecount(timestamp)
    
} else {
    #save old data into array, as we didnt receive the correct information
    set savedata(failurecount_count) $oldsavedata(failurecount_count)
    set savedata(failurecount_timestamp) $oldsavedata(failurecount_timestamp)
    set failurecount(count) $oldsavedata(failurecount_count)
    set failurecount(timestamp) $oldsavedata(failurecount_timestamp)
}

# calculate the difference
if {[info exists oldsavedata(failurecount_count)]} {
    set diff_failurecount [expr {$failurecount(count) - $oldsavedata(failurecount_count)}]
} else {
    set diff_failurecount 0
}

# and the time difference
if {[info exists oldsavedata(failurecount_timestamp)]} {
    set diff_failurecount_time [expr {$failurecount(timestamp) - $oldsavedata(failurecount_timestamp)}]
    if {[expr {$diff_failurecount_time < $timeinterval}]} {
        set diff_failurecount_time $timeinterval
    }
} else {
    set diff_failurecount_time $timeinterval
}

# by now we should have all the data 

# here we try to fix measurement errors by correcting time. 
# If we missed a measurement etc, we need to average this
# out so that we don't suddenly have peak values.

if {[info exists diff_numflowscache_time]} {
	set nfcc [expr {($diff_numflowscache / ($diff_numflowscache_time*1.0 + 1.0)) * $timeinterval}]
}
if {[info exists diff_exportedcount_time]} {
	set nec [expr {($diff_exportedcount / ($diff_exportedcount_time*1.0 + 1.0)) * $timeinterval}]
}
if {[info exists diff_failurecount_time]} {
	set nfc [expr {($diff_failurecount / ($diff_failurecount_time*1.0 + 1.0)) * $timeinterval}]
	if { [expr {$nfc > 0}] } {
        set nfc [expr {$nfc / 59.8133}]
    }
    if { [expr {$nfc < 0}] } {
        set nfc 0.0
    }
}

# only do this if all the values are properly set
if { [info exists nfcc] && [info exists nec] && [info exists nfc]} {
    
    # calculate the measured value
    set x_t [expr {$nfcc + $nec + $nfc}]
    
# Some useful debug data
#
#    action_syslog msg "========================"
#    action_syslog msg "DDOSDET Measured number: $x_t  flows/$timeinterval s"
#    action_syslog msg "       Flow cache:       $nfcc flows/$timeinterval s"
#    action_syslog msg "       Flow exports:     $nec  flows/$timeinterval s"
#    action_syslog msg "       Flow learn fails: $nfc  flows/$timeinterval s"


    if { [info exists varname] } {
        unset varname
    }
    
    # check if we need to initialize iteration variable
    if { ![info exists s_savedata(i_$day_type)] } {
        set s_savedata(i_$day_type) 0
    }
    
    # we are in the first season (learning)
    if { [expr {$s_savedata(i_$day_type) < $season_length}] && ![info exists s_savedata(prod_$day_type)]} {
        
        # set or increase the first season sum
        if { ![info exists s_savedata(first_season_sum_$day_type)] } {
            set s_savedata(first_season_sum_$day_type) $x_t
        } else {
            set s_savedata(first_season_sum_$day_type) [expr {$s_savedata(first_season_sum_$day_type) + $x_t}]
        }
        
        if { ![info exists s_savedata(seasonal_sum_$day_type)] } {
            set s_savedata(seasonal_sum_$day_type) $x_t
        } else {
            set s_savedata(seasonal_sum_$day_type) [expr {$s_savedata(seasonal_sum_$day_type) + $x_t}]
        }
        
        # calculate in what season part we are.
        set season_part [expr {$s_savedata(i_$day_type) / round($season_rate)}]
        
        # Last value of one seasonal-value averaging interval
        if { [expr {($s_savedata(i_$day_type) % $season_rate) == $season_rate-1}] } {
            
            if {[info exists varname]} { unset varname }
            
            append varname "$season_part" "_$day_type"
            
            set s_savedata(season_$varname) [expr {$s_savedata(seasonal_sum_$day_type) / $season_rate}]
            set s_savedata(seasonal_sum_$day_type) 0
        }
        
        # last season of learning
        if { [expr {$s_savedata(i_$day_type) == ($season_length-1)}] } {
            set s_savedata(base_$day_type) [expr { $s_savedata(first_season_sum_$day_type) / $season_length}]
            
            # check if theres an incomplete seasonal average
            if { [expr {($s_savedata(i_$day_type) % $season_rate) < $season_rate-1}] } {
                
                if {[info exists varname]} { unset varname }
                append varname "$season_part" "_$day_type"
            
                set s_savedata(season_$varname) [expr { $s_savedata(seasonal_sum_$day_type) / ($s_savedata(i_$day_type) % $season_rate + 1) }]
                set s_savedata(seasonal_sum_$day_type) 0
            }
            
            
            #substract base from all seasonal values
            for {set season 0} { $season < $num_season_parts } {incr season} {
                if {[info exists varname]} { unset varname }
                append varname "$season" "_$day_type"
                
                if { [info exists s_savedata(season_$varname)] } {
                    set s_savedata(season_$varname) [ expr { $s_savedata(season_$varname) - $s_savedata(base_$day_type) } ]
                }
            }
            
            set s_savedata(inter_a_$day_type) $s_savedata(season_0_$day_type)
            set s_savedata(inter_b_$day_type) $s_savedata(season_0_$day_type)
            set s_savedata(inter_a_index_$day_type) 0
            
            # we move to production
            set s_savedata(prod_$day_type) 1
      
      
#           Useful debug information: dump data. This can be used to import old context 
#           Information after a crash or something.

#           set searchToken [array startsearch s_savedata]
#           while {[array anymore s_savedata $searchToken]} {
#               set key [array nextelement s_savedata $searchToken]
#               set value $s_savedata($key)
#
#               # do something with key/value
#               action_syslog msg "set s_savedata($key) $value"
#           }
#           array donesearch s_savedata $searchToken

        }
    
    # we are in production mode
    } elseif { [info exists s_savedata(prod_$day_type)] } {
        
        #linear interpolation for current value
        if { [expr { ($s_savedata(i_$day_type) % $season_rate) == ($season_rate / 2)} ] } {
        
            if {[info exists varname]} { unset varname }
            set season_part [expr {$s_savedata(i_$day_type) / round($season_rate)}]
            append varname "$season_part" "_$day_type"
            
            set s_savedata(inter_a_$day_type) $s_savedata(season_$varname)
            
            
            if {[info exists varname]} { unset varname }
            set season_partb [expr {($season_part +1) % $num_season_parts}]
            append varname "$season_partb" "_$day_type"
            
            set s_savedata(inter_b_$day_type) $s_savedata(season_$varname)
            
            
            set s_savedata(inter_a_index_$day_type) $s_savedata(i_$day_type)
        }
        
        # calculate the current X value. 
        set x [expr { (( round ($s_savedata(i_$day_type) -  $s_savedata(inter_a_index_$day_type)) % $season_length ) *1.0 ) / $season_rate } ]
        
        set interpolation [expr { (1-$x) * $s_savedata(inter_a_$day_type) + ($x)*$s_savedata(inter_b_$day_type) } ]
        
        set expected_value [expr { $s_savedata(base_$day_type) + $interpolation }]
        
#        action_syslog msg "$s_savedata(base_$day_type) + $interpolation"
        
        #update base
        set old_base $s_savedata(base_$day_type)
        set s_savedata(base_$day_type) [expr { $alpha * ($x_t - $interpolation) + (1.0-$alpha) *  $s_savedata(base_$day_type)} ]
        
        # update seasonal sum
        if { ![info exists s_savedata(seasonal_sum_$day_type)] } {
            set s_savedata(seasonal_sum_$day_type) [expr { $x_t - $s_savedata(base_$day_type) }]
        } else {
            set s_savedata(seasonal_sum_$day_type) [expr {$s_savedata(seasonal_sum_$day_type) + ( $x_t - $s_savedata(base_$day_type) )}]
        }
        
        # update the seasonal sum based averages
        if { [expr { (($s_savedata(i_$day_type) % $season_rate) == ($season_rate - 1)) || ($s_savedata(i_$day_type) == ($season_length - 1) ) } ] } {
        
            if {[info exists varname]} { unset varname }
            set season_part [expr {$s_savedata(i_$day_type) / round($season_rate)}]
            append varname "$season_part" "_$day_type"
            
            # if a ddos attack was detected we do not update this seasonal sum
            if { [info exists s_savedata(ddos_detected)] } {
                unset s_savedata(ddos_detected)
            } else {
                set s_savedata(season_$varname) [expr { $gamma * ($s_savedata(seasonal_sum_$day_type) / ($s_savedata(i_$day_type) % $season_rate + 1)) + ( 1.0 - $gamma) * ($s_savedata(season_$varname)) } ]
            }
            
            set s_savedata(seasonal_sum_$day_type) 0
        }
    }
    
    #increment counter (and wrap it)
    set s_savedata(i_$day_type) [expr { ($s_savedata(i_$day_type) + 1) % $season_length} ]
    
    if { ![info exists expected_value] } {
#        action_syslog msg "Training period for '$day_type'. i=$s_savedata(i_$day_type) (of $season_length)"

#       save actual save data
        catch { context_save DDOSDET savedata }
        catch { context_save DDOSDET_seasons s_savedata }
        return
    } else {
        set season_part [expr {$s_savedata(i_$day_type) / round($season_rate)}]
#        action_syslog msg "DDOSDET Forecast: $expected_value  flows/$timeinterval s"
#        action_syslog msg "Production for '$day_type'. i=$s_savedata(i_$day_type) (of $season_length) $season_part/24"
    }
    
    # we need to store the expected value, so we can calculate the error
    # we also need to calculate the upperbound

    if { [info exists oldsavedata(expected_value)] } {
        set old_expected_value $oldsavedata(expected_value)
    } else {
        set old_expected_value $expected_value
    }
    set savedata(expected_value) $expected_value
    
    if {[info exists oldsavedata(inter_expected_value)]} {
        set savedata(inter_expected_value) [expr {$inter_alpha * $expected_value + (1.0-$inter_alpha) * $oldsavedata(inter_expected_value)}]
    } else {
        set savedata(inter_expected_value) $expected_value
    }
    
    # the error between the expected value and the actual measurement
    set forecasting_error [expr {$x_t - $old_expected_value}]
    
    # The decaying constant for the variance and standard deviation
    set teta 0.0035
    
    if { [info exists oldsavedata(est_variance)] } {
        set old_est_variance $oldsavedata(est_variance)
    } else {
        set old_est_variance [expr {$forecasting_error * $forecasting_error}]
    }
    
    set est_variance [expr { $teta * ($forecasting_error * $forecasting_error) + (1.0 - $teta) * $old_est_variance }]
    set std_deviation [expr { round([sqrt $est_variance]) }]
    
    set savedata(est_variance) $est_variance
    
    # Create a shadow value of the estimated variance, for use when
    # an attack has been detected (we dont want to learn from "dirty"
    # measurement data
    if {[info exists oldsavedata(inter_est_variance)]} {
        set savedata(inter_est_variance) [expr {$inter_alpha * $est_variance + (1.0-$inter_alpha) * $oldsavedata(inter_est_variance)}]
    } else {
        set savedata(inter_est_variance) $est_variance
    }
    
    # Calculate the upper threshold for the measurement based on the previous 
    # forecasted value. This uses the "deadzone" in case the std deviation is
    # too small, preventing instability
    if { [expr {$c_threshold * $std_deviation > $M_min}] } {
        set t_upper_t [expr {$old_expected_value + $c_threshold * $std_deviation}]
    } else {
        set t_upper_t [expr {$old_expected_value + $M_min}]
    }
    
#    action_syslog msg "DDOSDET Calculated T_upper,t: $t_upper_t"
    
    # if x_t > t_upper_t then we have a problem...
    
    # we need to do calculate the CUSUM values
    
    if { [info exists oldsavedata(s_t)] } {
        set old_s_t $oldsavedata(s_t)
    } else {
        set old_s_t 0
    }
    
#   useful debug information
#    action_syslog msg "$c_threshold * $std_deviation > $M_min"
#    action_syslog msg "new S_t = $old_s_t + ($x_t - $t_upper_t) > 0"
    
    # Calculate the new cusum value
    if { [expr {$old_s_t + ($x_t - $t_upper_t) > 0}] } {
        set s_t [expr {$old_s_t + ($x_t - $t_upper_t)}]
    } else {
        set s_t 0
    }
    
    set savedata(s_t) $s_t
    
    # Calculate the CUSUM threshold
    set t_cusum_t [expr {$c_cusum * $std_deviation}]
    
#    action_syslog msg "DDOSDET CUSUM : value: $s_t"
#    action_syslog msg "DDOSDET CUSUM : threshold: $t_cusum_t"
    
    if {[expr {$s_t > $t_cusum_t}] } {
    
        #prevent huge $s_t, to make it easier to forget an attack
        if { [expr {$s_t > 1.5*$t_cusum_t}] } {
            set savedata(s_t) [expr {1.5*$t_cusum_t}]
        }
        
        set s_savedata(ddos_detected) 1
        
        set s_savedata(base_$day_type) $old_base

        # Syslog a message indicating an anomaly        
        action_syslog msg "DDOSDET Anomaly: $savedata(s_t) > $t_cusum_t"
        
        
        # reset interpolated data to not take this one into account
        # to prevent learning the anomaly
        
        set savedata(inter_est_variance)    $oldsavedata(inter_est_variance)
        set savedata(est_variance)   $savedata(inter_est_variance)
        
    }
    
    # save actual save data
    catch { context_save DDOSDET savedata }
    catch { context_save DDOSDET_seasons s_savedata }
    
}

