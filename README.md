A small ruby program to manage Cisco FWSM or ASA configurations in a git
repository. If the device is in multiple context mode, the program will track
configuration changes to all contexts.

Rather than simply grab the configurations periodically and commit them to git,
this program attempts to group the changes into logical commits with an actual
author. An example commit log looks like:

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

This is accomplished by listening for configuration changes via syslog. Changes are saved in per-context buffers until a two minute timeout expires or a "write memory" command is received. At this point, the program logs into the firewall, downloads the new configuration, and commits the result with the captured command in the commit message and the username from the syslogs as the author. This is being used at the University of Rhode Island to monitor several ASA and FWSMs.

As a failsafe, all configurations are updated on startup and at least every two hours. In multiple context mode, `show context` is run eachtime the program connects to the ASA and any new contexts are backed up. When a new context is created and logging is configured, the configuration will be added automatically.

Logging Configuration
===========================
Logging should be configured to log with the hostname or context and no timestamps:

In single context mode:
```
logging device-id hostname
no logging timestamps
```

In multiple context mode:
```
logging device-id context-name
no logging timestamps
```

Configuration
==========================
For a full description of configuration, see config.example.yaml.

The program listens on one syslog port (UDP), which can be configured in the `:syslog:` section:

```
:syslog:
  :address: 0.0.0.0
  :port: 50514
  :device_maps:
    - fwsm
    - asa
```

The configuration for a device consists of three parts:
- config manager
- device map
- device
- user map

Since multiple devices may be sending logs to the same instance of the backup
program, a method is needed to map the syslogs to the device that sent them.
The device maps portion of the config file maps a device name (e.g. asa) to a
list of IP addresses:
```
  :asa:
    - 192.168.2.4
    - 192.168.2.5
```

Any syslogs from the listed IP addresses are assumed to come from the device
with the same name. A device is simply a (host, user, pass) tuple that the
program uses to login to the device:
```
  :asa:
    :host: 192.168.2.4
    :user: admin
    :pass: admin
```

The config_managers section has one entry per-device and the entry names
correspond to the device names. The config manager defines all of the
parameters for backing the config up in git, including:

- The path to the local git repository (required)
- A remote defined in the local git repository to which all changes are pushed
- tags. This functionality is intended for use with Stash and Jira. The example
  pulls out any strings of the form CR-[0-9] and adds the string to the commit
  message. This format represents a Jira issue number used for change tracking.
  When stash is used for configuration backups, it will link the Jira issues to
  the commits.
- user map to convert firewall usernames into email addresses suitable for git. 
```
  :asa:
    :repo:
      :path: /path/to/repo
      :push: origin master
    :tags:
      - CR\-[0-9]+
    :user_map: :fw_admins 
```
user_maps have the following form:

```
:user_maps:
  :fw_admins:
    Bob: Bob Barker <bob@foo.bar>
    john: John <john@foo.bar>
    :default_suffix: fw.foo.bar
```

Everything before the : is the firewall username; the remaining portion is the
mapped git author. The `:default_suffix:` is used for any users that do not
match the map. In this case, the firewall username will be converted to email
address form: user@default_suffix.
