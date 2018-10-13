open Test_helpers

let with_tcp ?(close = true) f =
  let tcp =
    Luv.TCP.init ()
    |> check_success_result "init"
  in

  f tcp;

  if close then begin
    Luv.Handle.close tcp;
    run ()
  end

let with_server_and_client ~server_logic ~client_logic =
  let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

  let server = Luv.TCP.init () |> check_success_result "server init" in
  Luv.TCP.bind server address |> check_success "bind";
  Luv.Stream.listen server begin fun result ->
    check_success "listen" result;
    let client = Luv.TCP.init () |> check_success_result "remote client init" in
    Luv.Stream.accept ~server ~client |> check_success "accept";
    server_logic server client
  end;

  let client = Luv.TCP.init () |> check_success_result "client init" in
  Luv.TCP.connect client address begin fun result ->
    check_success "connect" result;
    client_logic client address
  end;

  run ()

let tests = [
  "tcp", [
    "init, close", `Quick, begin fun () ->
      with_tcp ignore
    end;

    "nodelay", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        Luv.TCP.nodelay tcp true
        |> check_success "nodelay"
      end
    end;

    "keepalive", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        Luv.TCP.keepalive tcp None
        |> check_success "keepalive"
      end
    end;

    "simultaneous_accepts", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        Luv.TCP.simultaneous_accepts tcp true
        |> check_success "simultaneous_accepts"
      end
    end;

    "bind, getsockname", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

        Luv.TCP.bind tcp address
        |> check_success "bind";

        Luv.TCP.getsockname tcp
        |> check_success_result "getsockname result"
        |> check_address "getsockname address" address
      end
    end;

    "connect", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let finished = ref false in
        let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

        Luv.TCP.connect tcp address begin fun result ->
          check_error_code "connect" Luv.Error.econnrefused result;
          finished := true
        end;

        run ();
        Alcotest.(check bool) "finished" true !finished
      end
    end;

    (* Fails with a segfault if the binding doesn't retain a reference to the
       callback. *)
    "gc", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let finished = ref false in
        let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

        Luv.TCP.connect tcp address begin fun _result ->
          finished := true
        end;

        Gc.full_major ();

        run ();
        Alcotest.(check bool) "finished" true !finished
      end
    end;

    "connect, callback leak", `Slow, begin fun () ->
      let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

      no_memory_leak ~base_repetitions:1 begin fun _n ->
        with_tcp begin fun tcp ->
          Luv.TCP.connect tcp address (make_callback ());
          run ()
        end
      end
    end;

    "connect, synchronous error", `Quick, begin fun () ->
      let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in
      let result = ref Luv.Error.success in

      with_tcp begin fun tcp ->
        Luv.TCP.connect tcp address ignore;
        Luv.TCP.connect tcp address begin fun result' ->
          result := result'
        end;

        check_error_code "connect" Luv.Error.ealready !result;
        run ()
      end
    end;

    "connect, synchronous error leak", `Slow, begin fun () ->
      let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in

      no_memory_leak ~base_repetitions:1 begin fun _n ->
        with_tcp begin fun tcp ->
          Luv.TCP.connect tcp address ignore;
          Luv.TCP.connect tcp address ignore;
          run ()
        end
      end
    end;

    "connect, handle lifetime", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let address = Unix.(ADDR_INET (inet_addr_loopback, port ())) in
        Luv.TCP.connect tcp address begin fun result ->
          check_error_code "connect" Luv.Error.ecanceled result
        end
      end
    end;

    "listen, accept", `Quick, begin fun () ->
      let accepted = ref false in
      let connected = ref false in

      with_server_and_client
        ~server_logic:
          begin fun server client ->
            accepted := true;
            Luv.Handle.close client;
            Luv.Handle.close server
          end
        ~client_logic:
          begin fun client address ->
            Luv.TCP.getpeername client
            |> check_success_result "getpeername result"
            |> check_address "getpeername address" address;
            connected := true;
            Luv.Handle.close client
          end;

      Alcotest.(check bool) "accepted" true !accepted;
      Alcotest.(check bool) "connected" true !connected
    end;

    "read, write", `Quick, begin fun () ->
      let write_finished = ref false in
      let read_finished = ref false in
      let finalized = ref false in

      with_server_and_client
        ~server_logic:
          begin fun server client ->
            Luv.Stream.read_start client begin fun result ->
              let (buffer, length) = check_success_result "read_start" result in

              Alcotest.(check int) "length" 3 length;
              Alcotest.(check char) "byte 0" 'f' (Bigarray.Array1.get buffer 0);
              Alcotest.(check char) "byte 1" 'o' (Bigarray.Array1.get buffer 1);
              Alcotest.(check char) "byte 2" 'o' (Bigarray.Array1.get buffer 2);

              Luv.Handle.close client;
              Luv.Handle.close server;

              read_finished := true
            end
          end
        ~client_logic:
          begin fun client _address ->
            let buffer1 = Bigarray.(Array1.create Char C_layout 2) in
            let buffer2 = Bigarray.(Array1.create Char C_layout 1) in

            Bigarray.Array1.set buffer1 0 'f';
            Bigarray.Array1.set buffer1 1 'o';
            Bigarray.Array1.set buffer2 0 'o';

            Gc.finalise (fun _ -> finalized := true) buffer1;

            Luv.Stream.write client [buffer1; buffer2] begin fun result ->
              check_success "write" result;
              Luv.Handle.close client;
              write_finished := true
            end;

            Alcotest.(check bool) "asynchronous" false !write_finished;
            Gc.full_major ();
            Alcotest.(check bool) "retained" false !finalized
          end;

      Alcotest.(check bool) "write finished" true !write_finished;
      Alcotest.(check bool) "read finished" true !read_finished;

      Gc.full_major ();

      Alcotest.(check bool) "finalized" true !finalized
    end;

    "write: sync error", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let called = ref false in

        Luv.Stream.write tcp [] begin fun result ->
          check_error_code "write" Luv.Error.ebadf result;
          called := true
        end;

        Alcotest.(check bool) "called" true !called
      end
    end;

    "write: sync error leak", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        no_memory_leak begin fun _ ->
          Luv.Stream.write tcp [] (make_callback ())
        end
      end
    end;

    "try_write", `Quick, begin fun () ->
      let write_finished = ref false in
      let read_finished = ref false in

      with_server_and_client
        ~server_logic:
          begin fun server client ->
            Luv.Stream.read_start client begin fun result ->
              ignore (check_success_result "read_start" result);

              Luv.Handle.close client;
              Luv.Handle.close server;

              read_finished := true
            end
          end
        ~client_logic:
          begin fun client _address ->
            let buffer1 = Bigarray.(Array1.create Char C_layout 2) in
            let buffer2 = Bigarray.(Array1.create Char C_layout 1) in

            Bigarray.Array1.set buffer1 0 'f';
            Bigarray.Array1.set buffer1 1 'o';
            Bigarray.Array1.set buffer2 0 'o';

            Luv.Stream.try_write client [buffer1; buffer2]
            |> check_success_result "try_write"
            |> Alcotest.(check int) "count" 3;

            Luv.Handle.close client;
            write_finished := true
          end;

      Alcotest.(check bool) "write finished" true !write_finished;
      Alcotest.(check bool) "read finished" true !read_finished
    end;

    "try_write: error", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        Luv.Stream.try_write tcp []
        |> check_error_result "try_write" Luv.Error.ebadf
      end
    end;

    "shutdown", `Quick, begin fun () ->
      let server_finished = ref false in
      let client_finished = ref false in

      with_server_and_client
        ~server_logic:
          begin fun server client ->
            Luv.Stream.shutdown client begin fun result ->
              check_success "server shutdown" result;
              Luv.Handle.close client;
              Luv.Handle.close server;
              server_finished := true
            end
          end
        ~client_logic:
          begin fun client _address ->
            Luv.Stream.shutdown client begin fun result ->
              check_success "client shutdown" result;
              Luv.Handle.close client;
              client_finished := true
            end
          end;

      Alcotest.(check bool) "server finished" true !server_finished;
      Alcotest.(check bool) "client finished" true !client_finished
    end;

    "shutdown: sync error", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        let called = ref false in

        Luv.Stream.shutdown tcp begin fun result ->
          check_error_code "shutdown" Luv.Error.enotconn result;
          called := true
        end;

        Alcotest.(check bool) "called" true !called
      end
    end;

    "shutdown: sync error leak", `Quick, begin fun () ->
      with_tcp begin fun tcp ->
        no_memory_leak begin fun _ ->
          Luv.Stream.shutdown tcp (make_callback ())
        end
      end
    end;
  ]
]
