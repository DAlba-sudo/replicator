# Replicator

A quasi no-allocation tcp stream replication service for implementing semi-distributed systems.

## How to use?

```sh
# listens on all interfaces and binds to port 9090.
$ replicator -p 9090 0.0.0.0
```

### Building From Source

> Currently building from source is the only way to run the replicator service.

1. **Git Clone**

    Clone the repository from git by running the following code in a directory where you'd like to keep the source code.

    ```bash
    git clone https://github.com/DAlba-sudo/replicator.git
    ```

2. **Change Directory to Repository**

    Using `cd`, change directory into the recently cloned repository. 

    ```sh
    cd replicator/
    ```

3. **Zig Build**

    Using a `v0.12.0` zig compiler, run the following: `zig build`.

4. **Run the Service**

    The binary is located in the `zig-out/bin` directory. You can move this to `/bin` or anywhere else in the PATH that you'd like. 

    You run the service as such: `replicator -p 9090 127.0.0.1`.
    - Use `replicator -h` for potential flags that you can use.

### Configuration

Configuring the replicator service is slightly different than your typical app/program. Since the initial design goal for this was to take advantage of comptime-known inputs and outputs, we avoid memory allocation via syscalls and instead use `FixedBufferAllocators` backed by buffers living in the `bss` section of the executable.

To configure the app, edit the `src/config.zig` file with the values you'd like to use... then rebuild the app with `zig build`.
