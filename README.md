# Avast Omni Open-Source image build instructions

* install docker and git on a Linux PC (other host OS are not supported)
* clone `omni-firmware-public` repository
  ```
    $ git clone --recurse-submodules https://github.com/avast/omni-firmware.git
  ```
* run image build (takes some time)
  ```
    $ cd omni-firmware && make all
  ```
* symlink to resulting image is in `build/tmp/deploy/images/meson-apollo/apollo-image-6.6.1-prod-meson-apollo.ext4`

# How to build a single package?

  Let's say we want to build `iptables` package containing Avast modification. We can do that the following way:
  ```
    $ make all TARGET="iptables"
  ```
  
  The resulting package can be found in `build/tmp/deploy/deb/aarch64` along with iptables modules.

# Toolchain/SDK preparation
  ```
    $ make all TARGET="apollo-image -c populate_sdk"
  ```
   * after build is done, SDK installer can be found in `build/tmp/deploy/sdk/apollo-poky-glibc-x86_64-apollo-image-6.6.1-prod-aarch64-meson apollo-toolchain-6.6.1.sh`
