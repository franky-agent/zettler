//go:generate sh -c "if [ ! -f go.mod ]; then echo 'Initializing go.mod...'; go mod init .containifyci; else echo 'go.mod already exists. Skipping initialization.'; fi"
//go:generate go get github.com/containifyci/engine-ci/protos2
//go:generate go get github.com/containifyci/engine-ci/client
//go:generate go mod tidy

package main

import (
	"os"

	"github.com/containifyci/engine-ci/client/pkg/build"
	"github.com/containifyci/engine-ci/protos2"
)

func main() {
	os.Chdir("../")
	// Static fallback configuration
	opts := build.NewServiceBuild("zettler", protos2.BuildType_Zig)
	opts.Verbose = false
	opts.Folder = "./"
	opts.Image = ""
	opts.ContainerFiles = map[string]*protos2.ContainerFile{
		"build": DockerFile(),
	}
	opts.Properties = map[string]*build.ListValue{
		"goreleaser": build.NewList("true"),
		"optimize":   build.NewList("ReleaseFast"),
	}
	build.Build(opts)
}

func DockerFile() *protos2.ContainerFile {
	return &protos2.ContainerFile{
		Name: "0.17.0-dev-1267-300116b02-alpine",
		Content: `FROM --platform=$TARGETPLATFORM alpine:3.24
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG ZIG_VERSION=0.17.0-dev.1267+300116b02

RUN apk add --no-cache curl xz glfw-dev && \
	case "$TARGETPLATFORM" in \
        linux/amd64)  ZIG_ARCH=x86_64  ;; \
        linux/arm64)  ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    curl -L https://ziglang.org/builds/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz \
    | tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app

# Verify Zig installation
RUN zig version
`,
	}
}
