module storage_go_plugin

go 1.21

require storage_ext v0.0.0

require (
	github.com/fxamacker/cbor/v2 v2.7.0 // indirect
	github.com/x448/float16 v0.8.4 // indirect
)

replace storage_ext => ../nimhost/build/storage_ext_go
