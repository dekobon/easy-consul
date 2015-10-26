# Easy Three Node Consul Cluster

## Demo

 Watch how easy it is to boot a three node Consul cluster on Joyent!
 
 [![asciicast](https://asciinema.org/a/28784.png)](https://asciinema.org/a/28784)

## Getting started

  1. Check out the git repository.
  2. Install [Node.js](https://nodejs.org).
  3. Install [Joyent SmartDC CLI utilities](https://github.com/joyent/node-smartdc) and the [Node.js json utility](https://github.com/trentm/json): `npm install -g smartdc json`.
  4. [Configure the SmartDC environment variables `SDC_*`.](https://github.com/joyent/node-smartdc#cli-setup-and-authentication)
  5. Run the bootstrap script: `./bootstrap.sh`.
  6. Choose a data center that supports Triton (EU-AMS-1, US-EAST-1, US-SW-1).
  7. Choose a package size - smaller is probably better initially.
  8. Wait.
  9. Enable access to the Consul UI (port 8500) via the firewall rules, setup a VPN or a [bastion host](https://en.wikipedia.org/wiki/Bastion_host).
  10. Profit!
