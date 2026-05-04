FROM golang:1.22 AS builder
WORKDIR /opt/app-root/src
COPY go.mod ./
COPY main.go ./
RUN go build -o demo-app .

FROM golang:1.22 AS runtime
COPY --from=builder /opt/app-root/src/demo-app /usr/local/bin/demo-app
EXPOSE 8080
CMD ["demo-app"]
