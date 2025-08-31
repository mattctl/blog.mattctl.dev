# blog.mattctl.dev

Configuration and content for my personal blog.

For more detail on this approach to deploying a static site, see the write up on the blog: [Hello World | Hosting this Blog on Kubernetes ](https://blog.mattctl.dev/posts/hello-world/)

## Writing and previewing a post

Prerequisites:

- Go
- g++ (gcc-c++)

Building the site:

```bash
# this will install hugo if not present
make build
```

Serving a development version of the site for live preview:

```bash
make serve
```

Remove generated files:

```bash
make clean
```

Remove generated files and hugo binary
```shell
make full-clean
```

## Publishing

To publish a post, I simply commit and push to this repo.

```bash
git add .
git commit -m "add new post"
git push
```

This triggers a Github Actions workflow which renders the site to the `live` branch which is served by a nginx pod with a git-sync sidecar.
