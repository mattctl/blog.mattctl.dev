+++ 
draft = false
date = 2025-09-07T13:47:00Z
title = "Exposing Kubernetes Services Securely with Cloudflare Tunnels"
description = "How to securely expose a Kubernetes Service to the internet with Cloudflare Tunnels"
slug = "cloudflare-tunnels-k8s"

externalLink = ""

+++

In my [last post](../hello-world), I deliberately skipped over how I use Cloudflare Tunnels to expose this blog running on Kubernetes to the internet. 

As promised, let's have a look at how this works.

# Exposing a server to the internet

Cloudflare Tunnels are an offering from Cloudflare which lets you expose webservers to the internet without opening any firewall ports, or even revealing your IP address.

This can feel a little bit like magic, so let's get warmed up by having a look at a more hands-on way of achieving the same thing.

## The DIY option: ssh port-forwarding


Let's imagine:
- We have a webserver running locally on 10.1.2.3. 
- We don't want to open a port on our router to forward traffic to the webserver
- Our ISP uses Carrier Grade NAT (CGNAT) so our router doesn't have a publicly routable IP anyway.
- We have a host on the internet (perhaps a VPS with a hosting provider) with a publicly routable IP w.x.y.z.


With ssh port-forwarding, we can expose a service running on a `local_ip` and `local_port` on `remote_bind_ip` and `remote_port` on the host, vps, as follows:

```bash
ssh -R [remote_bind_ip]:[remote_port]:[local_ip]:[local_port] user@vps -N -f
```

Specifically in our case:

```bash
ssh -R w.x.y.z:80:10.1.2.3:80 user@w.x.y.z -N -f
```

```
+------------------+                   +------------------+
|      Local       | ====ssh-tunnel====|       VPS        |
|   10.1.2.3:80    | ==================|    w.x.y.z:80    |
+------------------+                   +------------------+
```


Now people can navigate to http://w.x.y.z and their request will be transparently routed to the webserver down an ssh tunnel.

Great! Or is it? There are some things we haven't considered.

### Consideration #1 - Tunnels die

An ssh session is just a TCP connection. There is no built in reconnect when the tunnel dies.

To make this a reliable way of exposing our server we'd need to find a way to restart failed tunnels. We could write a script to do this, or we could let someone else do the hard work (see [autossh](https://linux.die.net/man/1/autossh)).

### Consideration #2 - DNS

We can't be giving our raw IP addresses to users. They're scary. So we still need to create a DNS record to point blog.mattctl.dev at w.x.y.z.

### Consideration #3 - HTTPS

TLS is pretty much non-negotiable. We need a certificate for our site. And to rotate it when it expired.

### Consideration #4 - DDoS

What happens if someone uses bots to flood our site with traffic. Will my connection cope? Will the VPS cope? Will my partner start complaining Netflix has stopped working?

### Consideration #5 - Complexity

Will I manage to set all of this up? How will I document it? Will I be able to quickly make changes without having to re-understand a complex setup? Am I perhaps re-inventing the wheel?

### Consideration #6 - Scaling

What happens if I want to host another site, funny-cat-pics.mattctl.dev?  I could set up a reverse proxy on my existing VPS to forward requests to different backend servers based on the hostname, but that's extra complexity. I could rent another VPS, but it's 2025 - we don't just spin up a VM every time we have a problem.


## Cloudflare

Cloudflare Tunnels achieve the same result as the ssh port-forwarding method, but for free, and with all of the surrounding complexities abstracted away.

`cloudflared` runs as a lightweight local daemon and creates a connection (or tunnel) to Cloudflare's infrastructure.

We then need to set up a "Tunnel" on the Cloudflare website (or via the API), defining the hostname to expose our site on (blog.mattctl.dev) and the private server to forward requests to.

### DNS & TLS

Cloudflare will then automatically create the appropriate DNS record and generate a TLS cert for blog.mattctl.dev and start routing blog traffic to my blog via the tunnel.

### Stay alive

cloudflared has built in retry logic to recreate tunnels if they die due to, for instance, a network blip.

### Scaling

If I want to run another site I can just add a new host to the existing tunnel for free. And I no longer have to pay for a VPS at all.

### DDoS

If I fall victim to a DDoS attack it's much more likely Cloudflare (with its huge distributed infrastructure) can mitigate it than my VPS provider. And there are options for blocking certain countries or requiring a captcha which I can enable if necessary.

### Complexity

All I'm responsible for now is making sure cloudflared and my webserver stays running. All configuration options are well documented on Cloudflare's website.

# Cloudflare Tunnels on Kubernetes

## Recap

This blog is served by an nginx Pod running in my cluster. I covered how this is deployed, and how content is kept up to date in my [last post](../hello-world).

We can access the blog locally:
1. From the `blog` namespace as http://blog; or
2. From elsewhere on the cluster as http://blog.blog.svc.cluster.local

## Exposing via Cloudflare Tunnels

1. Use the wizard to create a tunnel on Cloudflare

2. Create a secret with a cloudflare token (created on Cloudflare's site):

```cloudflare-token.yml
# cloudflare-token.yml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-token
  namespace: blog
type: Opaque
stringData:
  token: super-secret-token
```

Note: Storing credentials in plaintext is not a good idea. Especially if committed to a git repo. Many options exist for managing Kubernetes Secrets securely. I use [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets) so I can safely manage credentials via GitOps.

3. Now deploy cloudflared:

```cloudflared.yaml
# cloudflared.yaml - adapted from example in cloudflare docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/deployment-guides/kubernetes/#5-create-pods-for-cloudflared
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: blog
spec:
  replicas: 2
  selector:
    matchLabels:
      pod: cloudflared
  template:
    metadata:
      labels:
        pod: cloudflared
    spec:
      containers:
        - image: cloudflare/cloudflared:latest
          name: cloudflared
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflare-token
                  key: token
          command:
            - cloudflared
            - tunnel
            - --no-autoupdate
            - --loglevel
            - debug
            - --metrics
            - 0.0.0.0:2000
            - run
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            failureThreshold: 1
            initialDelaySeconds: 10
            periodSeconds: 10
```

This should register and show up as connected on Cloudflare. At this point we should be able to access our site on the internet!

Note that this doesn't specify which resources will be exposed; that is defined on Cloudflare.

4. Add a NetworkPolicy

```cloudflare-egress-policy.yaml
# cloudflare-egress-policy.yaml
apiVersion: crd.projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: cloudflared-egress-policy
  namespace: blog
spec:
  selector: pod == "cloudflared"
  types:
    - Egress
  egress:
    # allow traffic to pods in 'blog' namespace
    - action: Allow
      destination:
        selector: all()
        namespaceSelector: kubernetes.io/metadata.name == "blog"
    # allow egress to internet
    - action: Allow
      destination:
        nets:
          - 0.0.0.0/0
          - ::/0
        # exclude local networks
        notNets:
          - 10.0.0.0/8
          - 192.168.0.0/16
          - 172.16.0.0/12
    # allow kube-dns
    - action: Allow
      protocol: UDP
      destination:
        selector: 'k8s-app == "kube-dns"'
        namespaceSelector: 'kubernetes.io/metadata.name == "kube-system"'
        ports: [53]
    - action: Allow
      protocol: TCP
      destination:
        selector: 'k8s-app == "kube-dns"'
        namespaceSelector: 'kubernetes.io/metadata.name == "kube-system"'
        ports: [53]
```

[The exact way to define a NetworkPolicy may vary based on which Cluster Network Interface (CNI) you use.] 

This adds an extra layer of protection by defining which resources the cloudflared pod can talk to. Here I am restricting it to just pods in the `blog` namespace, the internet, and the DNS server for the Kubernetes cluster. I explicitly prevent access to everything else on my cluster and local network.

Theoretically this means if a bad actor got into my Cloudflare account, they wouldn't be able to arbitrarily expose sensitive resources (e.g. the GUI for an internal firewall or hypervisor) simply by reconfiguring the tunnel.

The cloudflared container image does not include a shell (this minimises the attack surface and is best practice from a security perspective) so to verify the NetworkPolicy is working, we'll need to add a temporary debug container to the pod. This is a super useful trick for troubleshooting on Kubernetes and one it took me far too long to learn! To do this:

```bash
kubectl debug -n blog -it [cloudflared pod] --image=rockylinux/rockylinux:9.6
```

Now we have a shell inside the cloudflared pod where we can double check things are as expected:

```bash
# should fail
curl https://[firewall-lan-ip]

# should succeed
curl http://blog

# should fail (some service in another namespace)
curl http://[svc].[ns].svc.cluster.local
```

## Aside: cloudflared-operator

The deployment of cloudflared on Kubernetes as described above is quite naive. Configuring the tunnel is still manual. It would be more cloud-native to configure Cloudflare Tunnels automatically by reconciliation with instances of a Kubernetes CR (Custom Resource) i.e. the operator pattern. At least one project exists for this (see [cloudflared-operator](https://github.com/adyanth/cloudflare-operator)).

While this looks great, I have chosen not to use it for two reasons:

1. An operator feels like overkill for exposing one application. If I need to expose more in the future I will probably revisit it.
2. Operators have an inherently higher barrier to entry than the core Kubernetes resources (Service, Deployment, Pod and Secret) used in this guide. I hope this blog is useful to people new to Kubernetes and homelabbing, and I don't want to scare them off with unnecessary complexity.

# Summary

My blog running on Kubernetes is exposed to the internet using Cloudflare Tunnels via a cloudflared pod in the same namespace.

I use a NetworkPolicy to explicitly define which internal resources cloudflared can and cannot talk to.

This setup means I: 
- benefit from Cloudflare's ability to mitigate DDoS attacks
- don't have to spend any money on an internet accessible host such as a VPS
- don't need to manage TLS or DNS

Do you have any thoughts on this blog? Have you followed this guide in your own homelab? Run into an issue? Would you like to suggest a way to improve this guide? Is there another, better way to expose applications? Feel free to create an issue or start a discussion on [github](https://github.com/mattctl/blog.mattctl.dev).
