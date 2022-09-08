# unifios-tailscale

## Installation
1. Install `on-boot-script` from [unifios-utilities](https://github.com/unifi-utilities/unifios-utilities).

   ⚠ Make sure that you exit the `unifi-os` shell before moving onto step 2 (or you won't be able to find the `/mnt/data` directory).

2. Run the `remote-install.sh` script to install the latest version of the 
   unifios-tailscale package.
   
   ```sh
   curl -sSLq https://raw.githubusercontent.com/gridironsolutions/unifios-tailscale/master/remote-install.sh | sh
   ```
3. Follow the on-screen steps to configure `tailscale` and connect it to your network.
4. Confirm that `unifios-tailscale` is working by running `/mnt/data/unifios-tailscale/unifios-tailscale status`