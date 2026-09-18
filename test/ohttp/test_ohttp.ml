let () =
  Alcotest.run "ohttp"
    [
      ("media_type", Test_media_type.tests);
      ("rfc9458", Test_rfc9458.tests);
      ("key_config", Test_key_config.tests);
      ("encapsulation", Test_encapsulation.tests);
      ("chunked", Test_chunked.tests);
      ("upstream vectors", Test_upstream_vectors.tests);
      ("properties", Test_properties.tests);
    ]
