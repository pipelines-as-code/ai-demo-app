FROM registry.redhat.io/ubi9/go-toolset:1.22 AS builder
WORKDIR /opt/app-root/src
COPY go.mod ./
COPY main.go ./
RUN go build -o demo-app .

FROM registry.redhat.io/ubi9/ubi-minimal:latest
COPY --from=builder /opt/app-root/src/demo-app /usr/local/bin/demo-app
EXPOSE 8080
CMD ["demo-app"]
