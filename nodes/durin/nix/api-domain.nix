# Names on the API server certificate besides the local names
# (hostname, localhost, loopback, the service IP, and the LAN address).
# The website is www.1tdb.io and is not an API name.
# client is the name written into admin kubeconfigs. It must stay in names.
{
  names = [
    "k3s.1tdb.io"
  ];
  client = "k3s.1tdb.io";
}
