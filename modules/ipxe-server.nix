{ config, lib, pkgs, ... }:
let cfg = config.services.ipxed;
in {
  options.services.ipxed = {
    enable = lib.mkEnableOption "Enable the iPXEd";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7788;
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Repositories that are allowed to be built, in form of a list of owner/repo strings.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ipxed = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      script = ''
        ${pkgs.ipxed}/bin/ipxed \
          --port ${toString cfg.port} \
          --host ${cfg.host} \
          --allow ${builtins.concatStringsSep "," cfg.allow}
      '';
    };
  };
}
