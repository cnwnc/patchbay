crash_dump = Path.join(System.tmp_dir!(), "patchbay-erlang-crash.dump")
System.put_env("ERL_CRASH_DUMP", crash_dump)

ExUnit.start()
