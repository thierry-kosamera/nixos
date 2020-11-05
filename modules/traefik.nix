{ config, lib, pkgs, ... }:

with lib;
with (import ../msf_lib.nix);

let
  cfg = config.settings.services.traefik;
  system_cfg = config.settings.system;
  docker_cfg = config.settings.docker;
in

{

  options.settings.services.traefik = {
    enable = mkEnableOption "the Traefik service";

    version = mkOption {
      type = types.str;
      default = "2.3";
      readOnly = true;
    };

    image = mkOption {
      type = types.str;
      default = "traefik";
      readOnly = true;
    };

    service_name = mkOption {
      type = types.str;
      default = "nixos-traefik";
      readOnly = true;
    };

    dynamic_config = mkOption {
      type = with types; attrsOf (submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
          };
          value = mkOption {
            type = types.attrs;
          };
        };
      });
    };

    network_name = mkOption {
      type = types.str;
      default = "web";
    };

    logging_level = mkOption {
      type = types.enum [ "INFO" "DEBUG" "TRACE" ];
      default = "INFO";
    };

    accesslog = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
    };

    pilot_token = mkOption {
      type = types.str;
    };

    acme = {
      staging = mkOption {
        type = types.bool;
        default = false;
      };

      keytype = mkOption {
        type = types.str;
        default = "EC256";
        readOnly = true;
      };

      storage = mkOption {
        type = types.str;
        default = "/letsencrypt";
        readOnly = true;
      };

      email_address = mkOption {
        type = types.str;
      };

      dns_provider = mkOption {
        type = types.enum [ "azure" "route53" ];
      };
    };
  };

  config = mkIf cfg.enable {

    settings = {
      docker.enable = true;

      services.traefik.dynamic_config.default_config = {
        enable = true;
        value = {
          http = {
            middlewares = {
              default_middleware.chain.middlewares = [
                "security-headers"
                "compress"
              ];
              security-headers.headers = {
                sslredirect = true;
                stsPreload = true;
                stsSeconds = toString (365 * 24 * 60 * 60);
                stsIncludeSubdomains = true;
                customResponseHeaders = {
                  Expect-CT = "max-age=${toString (24 * 60 * 60)}, enforce";
                  Server = "";
                  X-Powered-By = "";
                  X-AspNet-Version = "";
                };
              };
              compress.compress = {};
            };

            # Forward to a non-routable IP address
            # https://tools.ietf.org/html/rfc5737
            services.black-hole-service.loadBalancer.servers = "192.0.2.1";
          };

          tls.options.default = {
            minVersion = "VersionTLS12";
            sniStrict = true;
            cipherSuites = [
              # https://godoc.org/crypto/tls#pkg-constants
              # TLS 1.2
              "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
              "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
              "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
              "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
              # TLS 1.3
              "TLS_AES_256_GCM_SHA384"
              "TLS_CHACHA20_POLY1305_SHA256"
            ];
          };
        };
      };
    };

    docker-containers = let
      static_config_file_name   = "traefik-static.yml";
      static_config_file_target = "/${static_config_file_name}";
      dynamic_config_directory_name   = "traefik-dynamic.conf.d";
      dynamic_config_directory_target = "/${dynamic_config_directory_name}";

      static_config_file_source = let
        staging_url = "http://acme-staging-v02.api.letsencrypt.org/directory";
        caserver    = optionalAttrs cfg.acme.staging { caserver = staging_url; };
        acme_template = {
          email = cfg.acme.email_address;
          storage = "${cfg.acme.storage}/acme.json";
          keyType = cfg.acme.keytype;
        } // caserver;
        accesslog = optionalAttrs cfg.accesslog.enable { accessLog = {}; };
        static_config = {
          global.sendAnonymousUsage = true;
          pilot.token = cfg.pilot_token;
          ping = {};
          log.level = cfg.logging_level;
          #metrics:
          #  prometheus: {}

          providers = {
            docker = {
              network = cfg.network_name;
              swarmMode = docker_cfg.swarm.enable;
              exposedbydefault = false;
            };
            file = {
              watch = true;
              directory = dynamic_config_directory_target;
            };
          };

          entryPoints = {
            web = {
              address = ":80";
              http.redirections.entryPoint = {
                to = "websecure";
                scheme = "https";
              };
            };
            websecure = {
              address = ":443";
              http = {
                middlewares = [ "default_middleware@file" ];
                tls.certResolver = "letsencrypt";
              };
            };
          };

          certificatesresolvers = {
            letsencrypt.acme =
              acme_template // {
                httpChallenge.entryPoint = "web";
              };
            letsencrypt_dns.acme =
              acme_template // {
                dnsChallenge = {
                  resolvers = [
                    "9.9.9.9:53"
                    "8.8.8.8:53"
                    "1.1.1.1:53"
                  ];
                  provider = cfg.acme.dns_provider;
                };
              };
          };
        } // accesslog;
      in pkgs.writeText static_config_file_name (builtins.toJSON static_config);

      dynamic_config_mounts = let
        buildConfigFile = key: configFile: let
          name = "${key}.yml";
          file = pkgs.writeText name (builtins.toJSON configFile.value);
        in "${file}:${dynamic_config_directory_target}/${name}:ro";
        buildConfigFiles = mapAttrsToList buildConfigFile;
      in msf_lib.compose [
           buildConfigFiles
           msf_lib.filterEnabled
         ] cfg.dynamic_config;

      dns_credentials_file_option = let
        file = system_cfg.secretsDirectory + cfg.acme.dns_provider;
      in optional (builtins.pathExists file) "--env-file=${file}";

    in {
      "${cfg.service_name}" = {
        image = "${cfg.image}:${cfg.version}";
        cmd = [
          "--configfile=${static_config_file_target}"
        ];
        ports = [
          "80:80"
          "443:443"
        ];
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
          "${static_config_file_source}:${static_config_file_target}:ro"
          "traefik_letsencrypt:${cfg.acme.storage}"
        ] ++ dynamic_config_mounts;
        workdir = "/";
        extraDockerOptions = [
          "--env=LEGO_EXPERIMENTAL_CNAME_SUPPORT=true"
          "--network=${cfg.network_name}"
          "--tmpfs=/tmp:rw,nodev,nosuid,noexec"
          "--tmpfs=/run:rw,nodev,nosuid,noexec"
          "--health-cmd=traefik healthcheck --ping"
          "--health-interval=60s"
          "--health-retries=3"
          "--health-timeout=3s"
        ] ++ dns_credentials_file_option;
      };
    };

    # We define an additional service to create the Traefik Docker network.
    systemd.services = let
      docker    = "${pkgs.docker}/bin/docker";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      traefik_docker_service_name = "docker-${cfg.service_name}";
      traefik_docker_service = "${traefik_docker_service_name}.service";
    in {
      docker-nixos-traefik-create-network = {
        inherit (cfg) enable;
        description = "Create the network for Traefik.";
        before      = [ traefik_docker_service ];
        requiredBy  = [ traefik_docker_service ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          if [ -z $(${docker} network list --filter "name=^${cfg.network_name}$" --quiet) ]; then
            ${docker} network create ${cfg.network_name}
          fi
        '';
      };

      # Restore the defaults to have proper logging in the systemd journal.
      # See GitHub NixOS/nixpkgs issue #102768 and PR #102769
      "${traefik_docker_service_name}" = {
        serviceConfig = {
          StandardOutput = mkForce "journal";
          StandardError  = mkForce "inherit";
        };
      };

      "${cfg.service_name}-pull" = {
        inherit (cfg) enable;
        description   = "Automatically pull the latest version of the Traefik image";
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${docker} pull ${cfg.image}:${cfg.version}
          ${systemctl} try-restart ${traefik_docker_service}.service
          prev_images="$(${docker} image ls \
            --quiet \
            --filter 'reference=${cfg.image}' \
            --filter 'before=${cfg.image}:${cfg.version}')"
          if [ ! -z "''${prev_images}" ]; then
            ${docker} image rm ''${prev_images}
          fi
        '';
        startAt = "Wed 03:00";
      };
    };
  };
}

