# iPXE Server

A simple server that takes a flake URL and serves the iPXE script, bzImage, and
initrd for the NixOS configuration it points to.

## Building

    nix build

or

    shards build


## Usage

    ipxed --help
