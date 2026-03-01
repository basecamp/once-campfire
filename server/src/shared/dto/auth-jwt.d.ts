declare module 'auth-jwt' {
  const factory: () => (request: unknown, reply: unknown) => Promise<void>;
  export default factory;
}
