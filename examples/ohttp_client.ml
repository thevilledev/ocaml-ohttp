(* A client.

   ohttp_client.exe KEYS-URL RELAY-URL TARGET-URL

   fetches the gateway's key configurations and sends a GET to the target
   through the relay:

   ohttp_client.exe http://127.0.0.1:8081/.well-known/ohttp-gateway \
   http://127.0.0.1:8082/relay https://example.com/

   Key configurations are fetched in the clear here. A real client fetches them
   over an authenticated channel, and in a way that gives every client the same
   ones (RFC 9458 Sections 6.1 and 7). *)

let () = Run.client ()
