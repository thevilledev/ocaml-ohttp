(* An Oblivious Gateway Resource.

   ohttp_gateway.exe PORT AUTHORITY=URL [AUTHORITY=URL ...]

   serves its key configurations at /.well-known/ohttp-gateway and requests at
   /gateway, for the targets named on the command line:

   ohttp_gateway.exe 8081 example.com=https://example.com *)

let () = Run.gateway ()
