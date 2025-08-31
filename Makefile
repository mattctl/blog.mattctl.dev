HUGO_VERSION = 66240338f1b908ca3b163384c8229943e74eb290 # v0.149.0
HUGO_BIN = ${HOME}/go/bin/hugo

.PHONY: default serve build clean help

default: help ## Show help if no target is given

${HUGO_BIN}:
	@echo Installing github.com/gohugio/hugo@${HUGO_VERSION}
	go install -tags extended github.com/gohugoio/hugo@${HUGO_VERSION}

build: ${HUGO_BIN} ## build site into public/
	${HUGO_BIN} build --cleanDestinationDir

serve: ${HUGO_BIN} ## serve site with live-reload
	${HUGO_BIN} serve --cleanDestinationDir

clean: ## Remove generated files (public/ and resources/)
	rm -rf public resources

full-clean: clean ## Remove generated files and ${HUGO_BIN}
	rm ${HUGO_BIN}

help: ## Show this help message
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
