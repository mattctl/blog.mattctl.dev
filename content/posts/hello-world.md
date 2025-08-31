+++ 
draft = false
date = 2025-08-28T20:42:24Z
title = "Hello World | Hosting this Blog on Kubernetes"
description = "Hi"
slug = "hello-world"

externalLink = ""

+++

This post was automatically deployed to my blog. All I had to do was write some markdown and commit.

## Overview

I am using the static site generator [hugo](https://gohugo.io) with the [hugo-coder](https://github.com/luizdepra/hugo-coder) theme. This means I can focus on writing / deploying my blog without worrying about CSS and JavaScript. 

This blog is defined in a git [repo](https://github.com/mattctl/blog.mattctl.dev-private) and deployed on Kubernetes with manifests in my (private) gitops/infra repo. I'll share the relevant snippets inline here.

Here's how it all fits together:

1. Write post in markdown and commit
2. GitHub actions renders site to `live` branch
3. git-sync sidecar picks up changes and pulls latest site for nginx to serve

## From idea to published post

### Writing

I wrote this post in markdown - great, already familiar with this from writing READMEs so no new syntax to learn. Whilst writing I used hugo's built in development server `hugo server` to run a live preview on localhost. That way, I can have side-by-side editor and preview - and no unpleasant surprises at deploy time.

### Publishing

```bash
git add .
git commit -m "add first post"
git push
```

Thats it.

### Deploying 

When I push my commit, GitHub actions builds my site and force pushes the rendered static output to a branch called `live`. This is essentially the [rendered manifests pattern]("https://akuity.io/blog/the-rendered-manifests-pattern") often used for GitOps deployments of helm charts.

The workflow for this was pretty simple and boils down to:

```.github/workflows/build.yml
#.github/workflows/build.yml
...
steps:
    - name: render site
        run: make build
    - name: push rendered site to live
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
        git config --global user.name "mattctl"
        git config --global user.email "227002067+mattctl@users.noreply.github.com"
        git checkout -b live
        git rm -r .
        git add public -f
        git commit -m "site rendered from commit ${{ github.sha}} | triggered by ${{ github.actor }}."
        git push origin live --force
...
```

If you want, compare the raw [markdown](https://github.com/mattctl/blog.mattctl.dev-private/blob/main/content/posts/hello-world.md) for this post, and the resulting [branch](https://github.com/mattctl/blog.mattctl.dev-private/tree/live).

To serve up the site, I use nginx running in my Homelab Kubernetes cluster.

This consists of a deployment, configmap and service defined in yaml in my GitOps repo. This is pretty standard stuff and just tells Kubernetes deploy an nginx webserver with some specific configuration, and make it available in-cluster at a friendly DNS name, of the format `<svc>.<namespace>.svc.cluster.local`, in this case `blog.blog.svc.cluster.local` thanks to my poor decision to call the namespace and the service the same thing.

```yaml
# nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blog
  namespace: blog
spec:
  selector:
    matchLabels:
      app: blog
  template:
    metadata:
      labels:
        app: blog
    spec:
      volumes:
        - name: www-data
          emptyDir: {}
        - name: nginx-conf
          configMap:
            name: nginx-conf
            items:
              - key: blog.conf
                path: blog.conf
      containers:
      - name: blog
        image: nginx:1.29.1
        resources:
          requests:
            memory: "128Mi"
            cpu: "0.1"
          limits:
            memory: "128Mi"
            cpu: "0.1"
        volumeMounts:
          - name: www-data
            mountPath: /data
          - name: nginx-conf
            mountPath: /etc/nginx/conf.d
            readOnly: true
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: blog
  namespace: blog
spec:
  selector:
    app: blog
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
  namespace: blog
data:
  blog.conf: |
    server {
      listen 80;
      server_name blog.mattctl.dev;

      root /data/blog.mattctl.dev-private.git/public;
      index index.html;

    location / {
        try_files $uri $uri/ /404.html;
    }

    error_page 404 /404.html;
    }

```

"But how does the blog content end up in the expected location of /data/blog.mattctl.dev-private.git/public?" my eagle-eyed readers will be asking at this point.

To keep the contents of the `www-data` volume up to date, I use [git-sync](https://github.com/kubernetes/git-sync), "a simple command that pulls a git repository into a local directory, waits for a while, then repeats". Running it as a sidecar just requires adding this snippet to my deployment:

```yaml
      containers:
      - name: git-sync
        image: registry.k8s.io/git-sync/git-sync:v4.4.2
        resources:
          requests:
            memory: "128Mi"
            cpu: "0.1"
          limits:
            memory: "128Mi"
            cpu: "0.1"
        volumeMounts:
          - name: www-data
            mountPath: /data
        env:
          - name: GIT_SYNC_REPO
            value: https://github.com/mattctl/blog.mattctl.dev-private.git
          - name: GIT_SYNC_BRANCH
            value: live
          - name: GIT_SYNC_ROOT
            value: /data
          - name: GIT_SYNC_ONE_TIME # keep syncing, don't exit
            value: "false"
          - name: GIT_SYNC_PERIOD # sync with remote every minute
            value: "60s"
```

Now git-sync will keep the directory served by nginx up to date with the latest commit on `live`.

So the rendered output of any commit I push will be live on this site at most 60 seconds later.

And all I had to do was write the post, and commit it. No scripts to run. No rsync command to push to a webserver to remember. Neat.

## Why Kubernetes?

"You could have just used GitHub pages", I hear you heckle.

I could, but I already had a homelab lying around. All of my applications are defined in one place and deployed using GitOps to an IaC defined Kubernetes cluster. Deploying this blog was just a case of adding a couple of manifests.

Hosting my blog locally should give me some "real" observability data to play with.

If you don't have a Kubernetes cluster, and don't want one (although I can't comprehend why you wouldn't) then there are many easier ways to deploy a static site - GitHub/GitLab pages, Cloudflare pages, rsync to a VPS...

## Exposing to the internet

I have deliberately glossed over how I expose the nginx service to the internet, to avoid the post becoming an essay. In short, I use Cloudflare Tunnels. I'll cover this in a future post.


## What I Learned

- _Lots_ of people bake static websites into docker images. This feels like a big antipattern to me.
- The rendered manifests pattern (borrowed from GitOps deployments of helm-charts) works really well for static sites.
- Zero-touch commit -> post being live on the internet massively reduces the cognitive load of writing a blogpost, and is _really_ satisfying.

## What's Next?

Hosting this on Kubernetes means there's a whole ecosystem of observability tools I can wire up and experiment with. I should be able to spin up a nice dashboard with some metrics for this blog.

If you've set up something similar or see a better way to do this, let me know on [GitHub](https://github.com/mattctl/blog.mattctl.dev-private)