let () =
  Alcotest.run "ohttp"
    [
      ("media_type", Test_media_type.tests);
      ("rfc9458", Test_rfc9458.tests);
      ("key_config", Test_key_config.tests);
      ("encapsulation", Test_encapsulation.tests);
      ("http binding", Test_http_binding.tests);
      ("chunked", Test_chunked.tests);
      ("upstream vectors", Test_upstream_vectors.tests);
      ("differential", Test_differential.tests);
      ("properties", Test_properties.tests);
    ]
