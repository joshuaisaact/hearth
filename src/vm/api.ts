import http from "node:http";

/** Thin client for the Firecracker REST API over Unix socket. */
export class FirecrackerApi {
  constructor(private socketPath: string) {}

  private request(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const jsonBody = body ? JSON.stringify(body) : undefined;
      const options: http.RequestOptions = {
        socketPath: this.socketPath,
        path,
        method,
        headers: jsonBody
          ? {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(jsonBody),
              Accept: "application/json",
            }
          : undefined,
      };

      const req = http.request(options, (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          if (res.statusCode && res.statusCode >= 300) {
            reject(new Error(`Firecracker ${method} ${path}: ${res.statusCode} ${data}`));
          } else {
            resolve();
          }
        });
      });

      req.on("error", reject);
      if (jsonBody) req.write(jsonBody);
      req.end();
    });
  }

  putMachineConfig(vcpuCount: number, memSizeMib: number): Promise<void> {
    return this.request("PUT", "/machine-config", {
      vcpu_count: vcpuCount,
      mem_size_mib: memSizeMib,
    });
  }

  putBootSource(kernelPath: string, bootArgs: string): Promise<void> {
    return this.request("PUT", "/boot-source", {
      kernel_image_path: kernelPath,
      boot_args: bootArgs,
    });
  }

  putDrive(
    id: string,
    path: string,
    isRoot: boolean,
    isReadOnly: boolean,
  ): Promise<void> {
    return this.request("PUT", `/drives/${id}`, {
      drive_id: id,
      path_on_host: path,
      is_root_device: isRoot,
      is_read_only: isReadOnly,
    });
  }

  putVsock(guestCid: number, udsPath: string): Promise<void> {
    return this.request("PUT", "/vsock", {
      guest_cid: guestCid,
      uds_path: udsPath,
    });
  }

  start(): Promise<void> {
    return this.request("PUT", "/actions", {
      action_type: "InstanceStart",
    });
  }

  pause(): Promise<void> {
    return this.request("PATCH", "/vm", { state: "Paused" });
  }

  resume(): Promise<void> {
    return this.request("PATCH", "/vm", { state: "Resumed" });
  }

  createSnapshot(snapshotPath: string, memFilePath: string): Promise<void> {
    return this.request("PUT", "/snapshot/create", {
      snapshot_type: "Full",
      snapshot_path: snapshotPath,
      mem_file_path: memFilePath,
    });
  }

  loadSnapshot(
    snapshotPath: string,
    memFilePath: string,
    resumeVm: boolean = false,
  ): Promise<void> {
    return this.request("PUT", "/snapshot/load", {
      snapshot_path: snapshotPath,
      mem_backend: {
        backend_path: memFilePath,
        backend_type: "File",
      },
      resume_vm: resumeVm,
    });
  }
}
