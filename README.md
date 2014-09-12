Cisco IOS DDoS Detection
===============

This collection of TCL scripts is a proof of concept DDoS attack detector for Cisco IOS, using flow-based data in IOS.
The implementation is based on a Cisco Catalyst 6500 using a Supervisor Engine 720. 

Currently there are no actions implemented for when an attack has been detected. 
The script will only write a message to the syslog to inform the administrator of the attack.

## Installation

To install the detection scripts, at least the two main scripts (tm_flow_count.tcl and tm_ddos_detection.tcl) need to be in an EEM directory on the switch.

Then using the usual commands, the EEM scripts can be activated:

```
switch # configure terminal
switch(config) # event manager policy tm_flow_count.tcl
switch(config) # event manager policy tm_ddos_detection.tcl
switch(config) # end
```

This starts the 24 hour learning period for the current day type (weekend/weekday). 
The first time it recognizes a new day type, it again starts a 24 hour learning period for that day type. 

## License

See LICENSE.txt
