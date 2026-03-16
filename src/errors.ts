export class HearthError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "HearthError";
  }
}

export class VmBootError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "VmBootError";
  }
}

export class ExecError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "ExecError";
  }
}

export class TimeoutError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "TimeoutError";
  }
}

export class AgentError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "AgentError";
  }
}

export class ResourceError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "ResourceError";
  }
}
