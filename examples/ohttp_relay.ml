(* An Oblivious Relay Resource.

   ohttp_relay.exe PORT GATEWAY-URL

   forwards what is posted to /relay:

   ohttp_relay.exe 8082 http://127.0.0.1:8081/gateway *)

let () = Run.relay ()
