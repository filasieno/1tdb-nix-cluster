# Pure shape checks for validateOptions.
# Owned by kubesysd/cluster. The node module and OpenBao call lib.check.
# Not a NixOS module and not an option.
{ lib }:
rec {
  nonEmptyStr = value: builtins.isString value && value != "";

  absolutePath = value: nonEmptyStr value && builtins.substring 0 1 value == "/";

  absolutePaths = paths: builtins.isList paths && paths != [ ] && lib.all absolutePath paths;

  port = value: builtins.isInt value && value >= 1 && value <= 65535;

  unsigned = value: builtins.isInt value && value >= 0;

  digitValue = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
  };

  wholeNumber = text: builtins.isString text && builtins.match "0|[1-9][0-9]*" text != null;

  decimal = text: lib.foldl' (acc: digit: acc * 10 + digitValue.${digit}) 0 (lib.stringToCharacters text);

  ipv4Octets = value:
    let
      parts = if builtins.isString value then lib.splitString "." value else [ ];
    in
    if builtins.length parts != 4 || lib.any (part: !wholeNumber part) parts then
      null
    else
      let
        nums = map decimal parts;
      in
      if lib.any (n: n > 255) nums then null else nums;

  isIpv4 = value: ipv4Octets value != null;

  pow2 = n: if n <= 0 then 1 else 2 * pow2 (n - 1);

  ipToInt = octets: lib.foldl' (acc: octet: acc * 256 + octet) 0 octets;

  parseCidr = value:
    let
      parts = if builtins.isString value then lib.splitString "/" value else [ ];
    in
    if builtins.length parts != 2 then
      null
    else
      let
        octets = ipv4Octets (builtins.elemAt parts 0);
        prefixText = builtins.elemAt parts 1;
      in
      if octets == null || !wholeNumber prefixText then
        null
      else
        let
          prefix = decimal prefixText;
        in
        if prefix > 32 then
          null
        else
          let
            network = ipToInt octets;
            block = pow2 (32 - prefix);
            aligned =
              if prefix == 0 then
                network == 0
              else if prefix == 32 then
                true
              else
                network - (builtins.div network block) * block == 0;
          in
          if !aligned then null else { inherit prefix network block; };

  isNetworkCidr = value: parseCidr value != null;

  ipInCidr = ip: cidr:
    let
      octets = ipv4Octets ip;
      parsed = parseCidr cidr;
    in
    octets != null
    && parsed != null
    && (
      let
        address = ipToInt octets;
      in
      address >= parsed.network && address < parsed.network + parsed.block
    );

  # Lowercase DNS label: [a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?
  hostname = value:
    builtins.isString value && builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" value != null;

  httpsUrl = value:
    nonEmptyStr value && lib.hasPrefix "https://" value && lib.removePrefix "https://" value != "";

  # https:// anywhere. http:// only for 127.0.0.1.
  loopbackOrHttps = value:
    httpsUrl value
    || (
      nonEmptyStr value
      && lib.hasPrefix "http://127.0.0.1" value
      && (
        let
          rest = lib.removePrefix "http://127.0.0.1" value;
        in
        rest == "" || lib.hasPrefix ":" rest || lib.hasPrefix "/" rest
      )
    );

  hostEqualsHttps = value:
    let
      parts = if builtins.isString value then lib.splitString "=" value else [ ];
    in
    builtins.length parts == 2 && hostname (builtins.elemAt parts 0) && httpsUrl (builtins.elemAt parts 1);
}
