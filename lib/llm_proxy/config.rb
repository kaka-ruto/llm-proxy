module LLMProxy
  Config = Struct.new(
    :server, keyword_init: true
  ) do
    def self.load(path)
      raw = YAML.safe_load_file(File.expand_path(path), permitted_classes: [Symbol])
      new(
        server: (raw["server"] || {}).transform_keys(&:to_sym)
      )
    end
  end
end
