{
  pkgs,
  name,
  server,
  ca,
  cert,
  key,
}:
pkgs.writeText "${name}.kubeconfig" (
  builtins.toJSON {
    apiVersion = "v1";
    kind = "Config";
    clusters = [
      {
        name = "local";
        cluster = {
          server = server;
          certificate-authority = ca;
        };
      }
    ];
    contexts = [
      {
        name = "local";
        context = {
          cluster = "local";
          user = name;
        };
      }
    ];
    current-context = "local";
    users = [
      {
        inherit name;
        user = {
          client-certificate = cert;
          client-key = key;
        };
      }
    ];
  }
)
