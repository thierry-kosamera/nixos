
########################################################################
#                                                                      #
# DO NOT EDIT THIS FILE, ALL EDITS SHOULD BE DONE IN THE GIT REPO,     #
# PUSHED TO GITHUB AND PULLED HERE.                                    #
#                                                                      #
# LOCAL EDITS WILL BE OVERWRITTEN.                                     #
#                                                                      #
########################################################################

{ config, pkgs, lib, ... }:

let
  cfg = config.settings.reverse_tunnel;
in

with lib;

{

  options = {
    settings.reverse_tunnel = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Whether to enable the reverse tunnel services.
        '';
      };

      remote_forward_port = mkOption {
        default = 0;
        type = types.ints.between 0 9999;
        description = ''
          The port on the relay servers.
        '';
      };

      relay_servers = mkOption {
        type = with types; listOf (submodule {
          options = {

            name = mkOption {
              type = types.str;
            };

            host = mkOption {
              type = types.str;
            };

            port_prefix = mkOption {
              type    = types.ints.between 0 6;
              default = 0;
            };

            prometheus_endpoint = mkOption {
              type    = types.bool;
              default = false;
            };

          };
        });
      };

      relay = {
        enable = mkOption {
          default = false;
          type = types.bool;
          description = ''
            Whether this server acts as an ssh relay.
          '';
        };

        ports = mkOption {
          default = [ 22 80 443 ];
          type = with types; listOf (ints.between 0 65535);
        };

        tunneller.keyFiles = mkOption {
          default = [ ];
          type = with types; listOf path;
          description = ''
            The list of key files which are allowed to access the tunneller user to create tunnels.
          '';
        };
        
      };
    };
  };

  config = mkIf (cfg.enable || cfg.relay.enable) {

    users.extraUsers.tunnel = {
      isNormalUser = false;
      isSystemUser = true;
      shell        = pkgs.nologin;
      extraGroups  = mkIf cfg.relay.enable [ config.settings.users.ssh-group ];
      openssh.authorizedKeys.keyFiles = mkIf cfg.relay.enable [ ../keys/tunnel ];
    };

    users.extraUsers.tunneller = mkIf cfg.relay.enable {
      isNormalUser = false;
      isSystemUser = true;
      shell        = pkgs.nologin;
      extraGroups  = [ config.settings.users.ssh-group ];
      openssh.authorizedKeys.keyFiles = cfg.relay.tunneller.keyFiles;
    };

    environment.etc.id_tunnel = mkIf cfg.enable {
      source = ./local/id_tunnel;
      mode = "0400";
      user = "tunnel";
      group = "tunnel";
    };

    systemd.services = let
      make_tunnel_service = conf: {
        "autossh-reverse-tunnel-${conf.name}" = {
          enable = true;
          description = "AutoSSH reverse tunnel service to ensure resilient ssh access";
          wants = [ "network.target" ];
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            AUTOSSH_GATETIME = "0";
            AUTOSSH_PORT = "0";
            AUTOSSH_MAXSTART = "10";
          };
          serviceConfig = {
            User = "tunnel";
            Restart = "always";
            RestartSec = "10min";
          };
          script = let
            tunnel_port = toString (conf.port_prefix * 10000 + cfg.remote_forward_port);
            prometheus_port = toString ((3 + conf.port_prefix) * 10000 + cfg.remote_forward_port);
          in ''
            for port in ${toString cfg.relay.ports}; do
              echo "Attempting to connect to ${conf.host} on port ''${port}"
              ${pkgs.autossh}/bin/autossh \
                -q -T -N \
                -o "ExitOnForwardFailure=yes" \
                -o "ServerAliveInterval=10" \
                -o "ServerAliveCountMax=5" \
                -o "ConnectTimeout=360" \
                -o "UpdateHostKeys=yes" \
                -o "StrictHostKeyChecking=no" \
                -o "GlobalKnownHostsFile=/dev/null" \
                -o "UserKnownHostsFile=/dev/null" \
                -o "IdentitiesOnly=yes" \
                -o "Compression=yes" \
                -o "ControlMaster=no" \
                -R ${tunnel_port}:localhost:22 \
                ${optionalString conf.prometheus_endpoint "-R ${prometheus_port}:localhost:9100 "}\
                -i /etc/id_tunnel \
                -p ''${port} \
                tunnel@${conf.host}
            done
          '';
        };
      };
      tunnel_services = optionalAttrs cfg.enable (
        foldr (conf: services: services // (make_tunnel_service conf)) {} cfg.relay_servers);

      monitoring_services = optionalAttrs cfg.relay.enable {
        port_monitor = {
          enable = true;
          restartIfChanged = false;
          unitConfig.X-StopOnRemoval = false;
          serviceConfig = {
            User = "root";
            Type = "oneshot";
          };
          script = let
            file = "/root/timetunnels.txt";
          in ''
            echo "###" | ${pkgs.coreutils}/bin/tee -a ${file}
            ${pkgs.coreutils}/bin/date | ${pkgs.coreutils}/bin/tee -a ${file}
            ${pkgs.iproute}/bin/ss -Htpln6 | ${pkgs.coreutils}/bin/sort -n | ${pkgs.coreutils}/bin/tee -a ${file}
          '';
          # Every 5 min
          startAt = "*:0/5:00";
        };
      };
    in
      tunnel_services // monitoring_services;
  };
}

