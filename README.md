# ab
Script for performing dnf operations out-of-band with an a/b root               
partition setup.                                                                
                                                                                
This is currently implemented using either lvm thin snapshots or
btrfs snapshots.
                                                                                
## Notes:                                                                       
- This is a *rough* proof of concept; for instance, LV and VG names are         
currently hardcoded, and there is no logic yet for properly managing the /boot  
partition. Currently the script just edits grubenv to change the root           
parameter.                                                                      
                                                                                
                                                                                
                                                                                
### Usage:                                                                      
                                                                                
`ab COMMAND`, where COMMAND is one of 
`mount|umount|stage|dnf|finalize|compare|cleanup|kernels|initrds`
A typical usage would be something like
```
ab stage && ab dnf update && ab finalize
```

