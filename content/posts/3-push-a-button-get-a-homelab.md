+++ 
draft = false
date = 2026-03-14T12:00:00Z
title = "Push a Button, Get a Homelab"
description = "Automatically provisioning my Hetzner Server Auction homelab"
slug = "push-a-button-get-a-homelab"

externalLink = ""

+++

Disclaimer for the purists in the community: yes I know it isn't strictly a *home*lab if it lives in a datacenter in Germany.

I've had a homelab since I got (really) into computers. It started off as a Raspberry Pi running a file server. It became a mini PC. Proxmox got involved. Then it became two mini PCs. Then it became 3 SFF PCs *plus* the mini PCs.

At some point in that last incarnation, the prices in Hetzner's Server Auction started looking attractive compared to the bump in my electricity bill.

## Phase 1 - Lift and Shift

I rented one server for around £70/month with 256GB RAM, 2 x 1TB SSD and a 16 core Xeon (w-2145). This roughly matched what I had "on-prem" (read: in the spare room). My homelab was pulling 200W. At the time this cost around £50/month. Electricity in the UK is expensive. 

It took a couple of weeks to migrate my existing setup into the new server. Since during this period I was paying for watt-hours *and* the Hetzner server, speed was of the essence - and automation, infrastructure-as-code, and general good practice was not.

Things I like about homelabbing: writing code; learning; experimenting with new technologies; seeing my setup evolve; breaking things.

Things I do not like about homelabbing: remembering manual steps; fixing things (which used to work).

## Phase 2 - Automate

In that spirit, I set out on a mission to fully automate my setup. The goal was to be able to pick a new server, click a button and... some time later... have a fully configured Homelab pop out.

One cool thing about Server Auction machines is they're billed hourly. During this period I could quickly spin up a second server to point my work-in-progress automation at when motivation struck - and pay roughly 5p/hour for the privilege. Then just as quickly spin it down when it started feeling like work.

### Scope

Installing and configuring the operating system (proxmox). Securing it behind a firewall. Setting up networking. DNS. Spinning up VMs. GitLab. Kubernetes. Deploying applications. Wiring up backups.

This was all stuff I sort of had. Had, in that it was all there, and sort of, as a descriptor for how well it worked and an ambitious answer to the question "how confident are you that you could actually rebuild this from scratch if it broke?".

### Hard Thing 1 - The Firewall Switcheroo

Fairly high up on The List of Architectures Which are Deeply Questionable and You Should Definitely Never Build is firewall-ception - a firewall protecting the host which that same firewall runs on as a VM.

Whilst normally ill-advised, building such a thing is not impossible. And in this case - where I have to pay the bill and where everything has to be automated - it makes a weird sort of sense. Some one off pain to engineer a reliable, repeatable monstrosity, if you will. If it breaks, I'll just re-provision on a fresh server.

With all sane design patterns out the window, I set about building the thing.

Getting Proxmox installed was the easy part. Just an ansible role which calls [installimage](https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage/). We make a few API calls to determine things like the gateway IP and MAC address for the server, and do a couple of bash one liners to get the interface device name and the disk names. 

Now the hard part. The plan: pre-configure a firewall VM to sit in front of Proxmox; set the firewall VM to start automatically on boot; render a network config file which puts Proxmox behind the firewall but don't actually load it yet; do the switcheroo (reboot the host and cross my fingers it comes up reachable).

Simple. 

It turns out this was easier said than done. 

Opnsense (the firewall of choice) doesn't have great (any) support for unattended installs. I tried mounting a virtual USB stick containing `config.xml` - I may well have missed something obvious, but I couldn't get Opnsense to pick up the config. I thought about baking the config into the VM image - but Opnsense uses ZFS so my usual `virt-customize --copy` party trick didn't work (and being already several abstraction levels below where I enjoy being, I left that idea there). 

In the end I click-opsed a basic configuration of an Opnsense VM (setting just enough for it to be able to boot) and uploaded it to object storage as a golden image. Now when I'm provisioning the firewall I import that image, boot it, then `scp` in a rendered `config.xml` and reload.

This solution is simultaneously a horrible janky hack and something which works without fail.

The network config for the host was a bit fiddly.

```
# pre-switcheroo /etc/network/interfaces

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto {{ interface }}
iface {{ interface }} inet static
	address {{ hetzner_ip }}/{{ netmask_cidr }}
	gateway {{ gateway }}
	up route add -net {{ network_address }} netmask {{ netmask }} gw {{ gateway }} dev {{ interface }}

auto vmbr0
iface vmbr0 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        bridge_maxwait 0

auto vmbr5
iface vmbr5 inet static
        address  {{ opnsense_lan_ip | ansible.utils.ipmath(1) }}/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0

auto vmbr11
iface vmbr11 inet static
        address  {{ opnsense_mgmt_ip | ansible.utils.ipmath(1) }}/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
```

This essentially configures the proxmox host to live on the main interface, bound to the public IP from Hetzner. We also configure a couple of virtual switches, as yet unused.

```
# post-switcheroo /etc/network/interfaces

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto {{ interface }}
iface {{ interface }} inet manual

pre-up ebtables -t nat -A POSTROUTING -j snat --to-src {{ mac_address }} -o {{ interface }}
pre-up ifconfig {{ interface }} hw ether 00:11:22:33:44:55

auto vmbr0
iface vmbr0 inet manual
        bridge-ports {{ interface }}
        bridge-stp off
        bridge-fd 0
        bridge_maxwait 0

auto vmbr5
iface vmbr5 inet static
        address  {{ opnsense_lan_ip | ansible.utils.ipmath(1) }}/24
        gateway	{{ opnsense_lan_ip }}
        bridge-ports none
        bridge-stp off
        bridge-fd 0

auto vmbr11
iface vmbr11 inet static
        address  {{ opnsense_mgmt_ip | ansible.utils.ipmath(1) }}/24
        gateway	{{ opnsense_mgmt_ip }}
        bridge-ports none
        bridge-stp off
        bridge-fd 0
```

Credit for this approach goes to [effgee on the Proxmox forums](https://forum.proxmox.com/threads/proxmox-hetzner-using-a-single-public-ipv4-address-ipv6-64-while-all-traffic-including-host-goes-through-virtualized-firewall-ex-pfsense.108050/). Essentially we don't assign the main interface an IP (because we need to give it to the Opnsense VM), and make sure any outgoing traffic has the right MAC address. vmbr5 is where VMs will live, and vmbr11 is for a static management interface for the firewall (because I want to reserve the right to deploy two servers at once and have the VMs sit in disjoint IP ranges).

The Opnsense VM itself has three interfaces: WAN (using the public IP), LAN (for VMs), and the third for firewall management:

```
# /etc/pve/qemu-server/xyz.conf
...
net0: virtio=<hetzner assigned MAC>,bridge=vmbr0,firewall=1,link_down=1
net1: virtio=<randomised MAC #1>,bridge=vmbr5,firewall=1
net2: virtio=<randomised MAC #2>,bridge=vmbr11,firewall=1
onboot: 1
...
```

We have `link_down=1` (i.e. disabled) on the WAN interface while proxmox is using the public IP during the initial opnsense bootstrap step, so they don't fight over the IP.

The switcheroo now boils down to flipping `link_down=0`, copying the proxmox network config into place, rebooting and 🤞.

Do I like this solution? No. Am I weirdly proud of it? Yes. Does it save me €2.04/month on a second public IP? Yes. Does it do everything I need it to automatically and let me move on with my life? Yes. Phew.

### Hard Thing 2 - Things Which Don't Have APIs

Glad to be out of the dark, dark woods of Hard Thing #1 I was now frolicking in the meadows of terraform. Declarative provisioning of VMs. Backed by an actual API!

I'm still configuring the services on those VMs - a minimal set of core things which need to be in place before we even think about Kubernetes (Bind9 for DNS, GitLab for... git, and a Tailscale subnet router to make everything routable on my wider network [I did say I kept a couple of mini PCs]) - using Ansible so granted, I'm still pinching my nose a bit. Think nice sunny meadow, but downwind from the sewage treatment works.

Sadly it was not long until I was back in the woods. To automatically route traffic to my other tailscale subnet routers I needed to set up a static route in Opnsense. No problem, that's in the API. To use the API I need an API token. There's no password-based API endpoint for generating one. Ah.

Generating an API token has to be click-opsed. Or does it. By inspecting the changes to `config.xml` upon making the changes manually I was able to work out the required change and do this (horrible) thing:

```
- name: Write API bootstrap script
  ansible.builtin.copy:
    content: |
      <?php
      $xml = new DOMDocument();
      $xml->load('/conf/config.xml');
      $xpath = new DOMXPath($xml);
      $rootUser = $xpath->query("/opnsense/system/user[name='root']")->item(0);
      if (!$rootUser) {
          fwrite(STDERR, "root user not found in config.xml\n");
          exit(1);
      }
      $apikeys = $rootUser->getElementsByTagName('apikeys')->item(0);
      if (!$apikeys) {
          $apikeys = $xml->createElement('apikeys');
          $rootUser->appendChild($apikeys);
      }
      $key    = base64_encode(random_bytes(60));
      $secret = base64_encode(random_bytes(60));
      $item = $xml->createElement('item');
      $item->appendChild($xml->createElement('key', $key));
      $item->appendChild($xml->createElement('secret', crypt($secret, '$6$')));
      $apikeys->appendChild($item);
      $xml->save('/conf/config.xml');
      echo json_encode(['key' => $key, 'secret' => $secret]);
    dest: /tmp/_opnsense_bootstrap_api.php
    mode: "0700"

- name: Inject API credentials into config.xml
  ansible.builtin.command: /usr/local/bin/php /tmp/_opnsense_bootstrap_api.php
  register: _api_result
  no_log: true

- name: Remove API bootstrap script
  ansible.builtin.file:
    path: /tmp/_opnsense_bootstrap_api.php
    state: absent
```

Faced with the constraint of the only programming languages being available on Opnsense being php and bash, and not being keen to manipulate XML in either, I delegated this one to Claude. (If an LLM isn't for writing a quick hack in programming language you don't know, what is it for?)

Two things which are not without risk: making config changes to firewalls, and poking around in XML where you've not been invited. Given this is an intersection of both of those things it's always going to be a bit risky, but hey we've got automation up our sleeves to rebuild the whole thing.

In contrast, adding the static routes via the API in python:

```python
for network in new_routes:
    log.info("Adding static route %s via %s", network, gateway_name)
    self._post(
        "routes/routes/addroute",
        {
            "route": {
                "network": network,
                "gateway": gateway_name,
                "descr": "",
                "disabled": "0",
            }
        },
    )
```

Don't get me wrong, Opnsense is a fantastic piece of OSS. It's incredible to get a fully featured firewall for free. But (like a lot of software, free and paid) a couple of oversights mean it has to be shoehorned into an infrastructure-as-code environment with nasty little hacks.

### Hard Thing 3 - Compound Flakiness

As I added more steps to the automation pipeline, the more likely it became that at least one of them would fail due to some transient issue. If you have one step with a 5% failure rate that's a 95% chance of success; if you have 10 such steps, it's less than 60%.

Failure, I found, was especially likely when interacting with Hetzner Object Storage. It was a no-brainer for me to pick this when egress within a Hetzner region (including to auction servers) is free. Sadly it is not exactly reliable.

To handle this and other spurious errors, I built the concept of a retryable `step` into my automation code:

```python
@_step("gitlab", retries=2, retry_delay=30.0)
def step_gitlab(...) -> None:
  ...
```

Now if my code to provision GitLab fails - due to say Object Storage flaking on me when I ask for my GitLab backup - it will automatically retry.

In practice this means end-to-end runs are now very unlikely to fail unless I've introduced a genuine bug.

### Hard Thing 4 - But It Works on *My* Machine

Ah yes, that old chestnut. A phrase which has had no place in the IT industry for at least 15 years.

To keep the runtime environment consistent across my laptop and CI pipelines in GitLab I run everything in a toolbox container. The Dockerfile defines the required dependencies - things like ansible, python packages, age/sops (for en/de-crypting secrets), and the aws cli (for object storage). I add a custom `entrypoint.sh` which handles configuring tools like sops, age and kubectl based on the environment variables passed in.

To drop into a toolbox shell locally is as simple as:

```
make toolbox
```

Under the hood, this calls a script which runs the toolbox container with the current directory mounted to `/workspace/` and the necessary environment variables passed in. The environment variables themselves are sourced from an encrypted file `secrets.sops.yaml` with `get-var.sh` as a convenience. 

[sops](https://github.com/getsops/sops) is a lightweight tool for managing secrets. You can plug it into multiple encryption backends. I use [age](https://github.com/FiloSottile/age). It's particularly good for structured files like yaml, because it only encrypts the values.

To make sops files easier to work with than having to remember all the flags for the `sops` binary, I've written a small python wrapper, `sops.py` - [Appendix #1](#appendix-1---sopspy). This makes it possible to work with sops files from python as if they were regular dicts:

```python

s = Sops("/path/to/secrets.sops.yaml")

# access an item
api_key = s["api_key"]

# set an item
s["some_new_secret"] = "super-spicy-secret"

# iterate over items
for k, v in s.items():
  ...
```

One way I use `sops.py` is to keep GitLab CI/CD variables in sync with what's in `secrets.sops.yaml` in the repo. I iterate over the secrets and generate input for a small Terraform module which uses the GitLab provider to set CI/CD variables. This runs every time a branch is merged to main. 

And now my feeble human brain doesn't need to think about secrets management at all.

## Summary

I now have a fully automated pipeline which takes a fresh Hetzner auction server and turns it into my homelab. That means installing Proxmox; configuring an Opnsense firewall (don't look too closely at that bit...); provisioning and configuring service VMs for DNS and Tailscale; spinning up a GitLab instance and automatically restoring my repos from a backup (when object storage agrees); and provisioning a Kubernetes cluster and bootstrapping it with a monitoring stack, declarative certificate and DNS management, a GitLab runner for CI jobs, and applications.

And all of that happens in 1 hour.

I can now spin up a fully representative homelab reference environment to test risky changes against, or run an experiment on, without risking breaking services I rely on. And pay only 5p/hour for the privilege.

I completed the migration from [Phase 1](#phase-1---lift-and-shift)'s manually configured server this week. Because it's now *much* easier to migrate, I was able to pick a much smaller server without worrying about headroom. I'm now running on an i7-7700, 64GB RAM, and 2 x 480GB SSDs. For the grand total of £41/month.

Prices were quite high at the time, but I've got my eyes peeled - and my pipelines primed - for a bargain deal.

## What's Next?

- Autoscaling into cloud VMs. The idea being: "pay for just as much 24/7 capacity as you need and burst into the cloud for everything else". I'm already experimenting with this for my GitLab CI/CD jobs. Watch this space.
- Automated Regression Testing. Having done the hard part (automating everything), it feels like a no-brainer to run a scheduled end-to-end test so that I know as soon as something has broken. 


## Appendix #1 - sops.py

Here's the full implementation of my sops wrapper for reference:

```python
import json
import subprocess
from typing import Any, Generator, Iterator
import yaml

from pathlib import Path


class Sops:
    """Utility class for working with SOPS-encrypted files.

    Wraps the sops CLI to provide read and write access to encrypted YAML files.
    Requires the sops binary to be available on PATH and appropriate age/KMS
    keys to be configured in the environment.

    Args:
        path: Path to the SOPS-encrypted file.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)

    def exists(self) -> bool:
        """Check if the SOPS file exists on disk.

        Returns:
            True if the file exists, False otherwise.
        """
        return self.path.exists()

    def _raw(self) -> str:
        """Decrypt the SOPS file and return the raw plaintext output.

        Returns:
            Decrypted file contents as a string.

        Raises:
            FileNotFoundError: If the file does not exist.
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        if not self.exists():
            raise FileNotFoundError(f"SOPS file '{self.path}' does not exist.")
        result = subprocess.run(
            ["sops", "--decrypt", str(self.path)],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout

    def to_dict(self) -> dict[str, Any]:
        """Decrypt the SOPS file and return its contents as a dictionary.

        Returns:
            Parsed YAML contents as a dict.

        Raises:
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        return yaml.safe_load(self._raw())

    def update_key(self, key: str, value: Any) -> None:
        """Set or update a top-level key in the SOPS file.

        The value is serialised as JSON, so strings, integers, booleans,
        lists, and dicts are all supported.

        If the file does not exist, it is created and encrypted in place.

        Args:
            key: The top-level key to set.
            value: The value to set. Must be JSON-serialisable.

        Raises:
            subprocess.CalledProcessError: If sops fails to encrypt or update the file.
        """
        if not self.exists():
            # If the file doesn't exist, create it with the new key-value pair
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(yaml.dump({key: value}))
            subprocess.run(
                ["sops", "--encrypt", "--in-place", str(self.path)],
                check=True,
            )
            return
        subprocess.run(
            ["sops", "--set", f'["{key}"] {json.dumps(value)}', str(self.path)],
            check=True,
        )

    def delete_key(self, key: str) -> None:
        """Delete a top-level key from the SOPS file.

        Decrypts the file, removes the key, then re-encrypts in place.
        If re-encryption fails the original encrypted file is restored.

        Args:
            key: The top-level key to delete.

        Raises:
            KeyError: If the file does not exist, or the key is not found.
            subprocess.CalledProcessError: If sops fails to re-encrypt the file.
        """
        if not self.exists():
            raise KeyError(
                f"Key '{key}' not found because file '{self.path}' does not exist."
            )
        data = self.to_dict()
        if key not in data:
            raise KeyError(f"Key '{key}' not found in SOPS file.")
        del data[key]
        backup = self.path.read_bytes()
        try:
            self.path.write_text(yaml.dump(data))
            subprocess.run(
                ["sops", "--encrypt", "--in-place", str(self.path)],
                check=True,
            )
        except Exception:
            self.path.write_bytes(backup)
            raise

    def __getitem__(self, key: str) -> Any:
        """Get a value by key, e.g. s["my_key"].

        Args:
            key: The top-level key to retrieve.

        Raises:
            KeyError: If the key does not exist in the file.
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        return self.to_dict()[key]

    def __setitem__(self, key: str, value: Any) -> None:
        """Set a value by key, e.g. s["my_key"] = "value".

        Args:
            key: The top-level key to set.
            value: The value to set. Must be JSON-serialisable.

        Raises:
            subprocess.CalledProcessError: If sops fails to update the file.
        """
        self.update_key(key, value)

    def __delitem__(self, key: str) -> None:
        """Delete a key, e.g. del s["my_key"].

        Args:
            key: The top-level key to delete.

        Raises:
            KeyError: If the key does not exist in the file.
            subprocess.CalledProcessError: If sops fails to re-encrypt the file.
        """
        self.delete_key(key)

    def __contains__(self, key: object) -> bool:
        """Check if a key exists, e.g. "my_key" in s.

        Args:
            key: The key to check.

        Raises:
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        return key in self.to_dict()

    def __len__(self) -> int:
        """Return the number of top-level keys in the file.

        Raises:
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        return len(self.to_dict())

    def __iter__(self) -> Iterator[str]:
        """Iterate over top-level keys, e.g. for key in s.

        Raises:
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        yield from self.to_dict()

    def __repr__(self) -> str:
        """Return a string representation showing the file path."""
        return f"Sops({str(self.path)!r})"

    def items(self) -> Generator[tuple[str, Any], None, None]:
        """Iterate over key-value pairs in the decrypted SOPS file.

        Yields:
            Tuples of (key, value) for each top-level entry in the file.

        Raises:
            subprocess.CalledProcessError: If sops fails to decrypt the file.
        """
        data = self.to_dict()
        for key, value in data.items():
            yield key, value

```
