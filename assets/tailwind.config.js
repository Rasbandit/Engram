// Tailwind config for Phoenix marketing pages (EEx templates).
// The React SPA in frontend/ has its own separate Tailwind pipeline.
module.exports = {
  content: [
    "../lib/engram_web/components/**/*.{heex,ex}",
    "../lib/engram_web/controllers/**/*.{heex,ex}"
  ]
}
