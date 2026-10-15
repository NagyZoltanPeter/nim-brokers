module storage_go_host_lib

go 1.21

require (
	notes_ext v0.0.0
	storagelib v0.0.0
)

require (
	github.com/fxamacker/cbor/v2 v2.7.0 // indirect
	github.com/x448/float16 v0.8.4 // indirect
)

replace (
	notes_ext => ../nimlib/build/notes_ext_go
	storagelib => ../nimlib/build/storagelib_go
)
