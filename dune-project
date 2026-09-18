(lang dune 3.12)
(name ohttp)
(generate_opam_files false)
(source (github thevilledev/ocaml-ohttp))
(license ISC)
(authors "Ville Vesilehto <ville@vesilehto.fi>")
(maintainers "Ville Vesilehto <ville@vesilehto.fi>")

(package
 (name bhttp)
 (synopsis "Binary Representation of HTTP Messages (RFC 9292) for OCaml")
 (description
  "A codec for Binary HTTP (RFC 9292): known-length and indeterminate-length requests and responses, informational responses, trailers, padding, and truncation. It has no dependencies and performs no I/O.")
 (tags (http bhttp rfc9292 "binary http" codec)))

(package
 (name ohttp)
 (synopsis "Oblivious HTTP (RFC 9458) for OCaml")
 (description
  "An implementation of Oblivious HTTP (RFC 9458): key configurations, and request and response encapsulation for clients and gateways, over the hpke package. It performs no I/O, so any HTTP library can carry the messages.")
 (tags (cryptography privacy ohttp rfc9458 "oblivious http" hpke)))
