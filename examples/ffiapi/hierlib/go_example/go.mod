module github.com/status-im/nim-brokers/examples/ffiapi/hierlib/go_example

go 1.21

require hierlib v0.0.0

require (
	github.com/fxamacker/cbor/v2 v2.7.0 // indirect
	github.com/x448/float16 v0.8.4 // indirect
)

replace hierlib => ../nimlib/build/hierlib_go
