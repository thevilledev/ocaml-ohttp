let () =
  Alcotest.run "bhttp"
    [
      ("hex", Test_hex.tests);
      ("varint", Test_varint.tests);
      ("rfc9292", Test_vectors.tests);
      ("decode", Test_decode.tests);
      ("encode", Test_encode.tests);
      ("field", Test_field.tests);
      ("differential", Test_differential.tests);
      ("properties", Test_properties.tests);
    ]
