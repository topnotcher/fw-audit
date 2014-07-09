A small ruby program to manage Cisco FWSM or ASA context configurations in a git repository.

Rather than simply grab the configurations periodically and commit them to git, this program attempts to group the changes into logical commits with an actual author. An example commit log looks like:

```
commit 634b419e6013375529088df8509ace4c30c0c439
Author: Greg Bowser <topnotcher@gmail.com>
Date:   Thu Apr 24 08:49:47 2014 -0400

     Changes to contexta by greg
    
    2014-04-24 08:49:42 -0400[contexta](greg): name 198.51.100.2 Shockwave
    2014-04-24 08:49:42 -0400[contexta](greg): asdm location 198.51.100.2 255.255.255.255 inside
    2014-04-24 08:49:42 -0400[contexta](greg): object-group network DM_INLINE_NETWORK_1
    2014-04-24 08:49:42 -0400[contexta](greg): network-object host 198.51.100.2
    2014-04-24 08:49:42 -0400[contexta](greg): network-object host 198.51.100.14
    2014-04-24 08:49:46 -0400[contexta](greg): write memory
```

This is accomplished by listening for configuration changes via syslog. Changes are saved in per-context buffers until a 30 second timeout expires or a "write memory" command is received. At this point, the program logs into the firewall, downloads the new configuration, and commits the result with the captured command in the commit message and the username from the syslogs as the author. This is being used at the University of Rhode Island to monitor several ASA and FWSMs.
