require 'fastlane/swift_fastlane_function.rb'

module Fastlane
  class SwiftFastlaneAPIGenerator
    attr_accessor :tools_with_option_file
    attr_accessor :action_options_to_ignore

    def initialize
      require 'fastlane'
      require 'fastlane/documentation/actions_list'
      Fastlane.load_actions
      # Tools that can be used with <Toolname>file, like Deliverfile, Screengrabfile
      # this is important because we need to generate the proper api for these by creating a protocol
      # with default implementation we can use in the Fastlane.swift API if people want to use
      # <Toolname>file.swift files.
      self.tools_with_option_file = ["snapshot", "screengrab", "scan", "precheck", "match", "gym", "deliver"].to_set
      self.action_options_to_ignore = {
        "cocoapods" => ["error_callback"].to_set,
        "sh" => ["error_calback"].to_set,
        "precheck" => [
          "negative_apple_sentiment",
          "placeholder_text",
          "other_platforms",
          "future_functionality",
          "test_words",
          "curse_words",
          "custom_text",
          "copyright_date",
          "unreachable_urls"
        ].to_set
      }
    end

    def generate_swift(target_path: "swift/Fastlane.swift")
      file_content = []
      file_content << "import Foundation"

      generated_tool_classes = []
      generated_tool_protocols = []
      ActionsList.all_actions do |action|
        swift_function = process_action(action: action)
        if defined?(swift_function.class_name)
          generated_tool_classes << swift_function.class_name
          generated_tool_protocols << swift_function.protocol_name
        end
        unless swift_function
          next
        end

        file_content << swift_function.swift_code
      end
      file_content << "" # newline because we're adding an extension
      file_content << "// These are all the parsing functions needed to transform our data into the expected types"
      file_content << generate_lanefile_parsing_functions

      file_content << "// [TOOL_OBJECTS] These objects can potentially be replaced when we compile the user's Fastfile.swift"
      tool_objects = generate_lanefile_tool_objects(classes: generated_tool_classes)
      file_content << tool_objects
      file_content << "// end of [TOOL_OBJECTS]"
      file_content << "" # newline because it's the end of the file adding an extension

      file_content = file_content.join("\n")

      File.write(target_path, file_content)
      UI.success(target_path)

      generate_default_implementation(protocols: generated_tool_protocols, classes: generated_tool_classes)
    end

    def generate_default_implementation(protocols: nil, classes: nil)
      class_defs = protocols.zip(classes).map do |protocol, class_name|
        "class #{class_name}: #{protocol} {}"
      end

      class_defs << ""
      file_content = class_defs.join("\n")

      target_path = "swift/DefaultFileImplementations.swift"
      File.write(target_path, file_content)
      UI.success(target_path)
    end

    def generate_lanefile_parsing_functions
      parsing_functions = 'func parseArray(fromString: String, function: String = #function) -> [String] {
  verbose(message: "parsing an Array from data: \(fromString), from function: \(function)")
  let potentialArray: String
  if fromString.characters.count < 2 {
    potentialArray = "[\(fromString)]"
  } else {
    potentialArray = fromString
  }
  let array: [String] = try! JSONSerialization.jsonObject(with: potentialArray.data(using: .utf8)!, options: []) as! [String]
  return array
}

func parseDictionary(fromString: String, function: String = #function) -> [String : String] {
  verbose(message: "parsing an Array from data: \(fromString), from function: \(function)")
  let potentialDictionary: String
  if fromString.characters.count < 2 {
    verbose(message: "Dictionary value too small: \(fromString), from function: \(function)")
    potentialDictionary = "{}"
  } else {
      potentialDictionary = fromString
  }
  let dictionary: [String : String] = try! JSONSerialization.jsonObject(with: potentialDictionary.data(using: .utf8)!, options: []) as! [String : String]
  return dictionary
}

func parseBool(fromString: String, function: String = #function) -> Bool {
  verbose(message: "parsing a Bool from data: \(fromString), from function: \(function)")
  return NSString(string: fromString).boolValue
}

func parseInt(fromString: String, function: String = #function) -> Int {
  verbose(message: "parsing a Bool from data: \(fromString), from function: \(function)")
  return NSString(string: fromString).integerValue
}
      '
      return parsing_functions
    end

    def generate_lanefile_tool_objects(classes: nil)
      objects = classes.map do |filename|
        "let #{filename.downcase}: #{filename} = #{filename}()"
      end
      return objects
    end

    def generate_tool_protocol(tool_swift_function: nil)
      protocol_content_array = []
      protocol_name = tool_swift_function.protocol_name

      protocol_content_array << "protocol #{protocol_name}: class {"
      protocol_content_array += tool_swift_function.swift_vars
      protocol_content_array << "}"
      protocol_content_array << ""

      protocol_content_array << "extension #{protocol_name} {"
      protocol_content_array += tool_swift_function.swift_default_implementations
      protocol_content_array << "}"
      protocol_content_array << ""

      target_path = "swift/#{protocol_name}.swift"
      file_content = protocol_content_array.join("\n")
      File.write(target_path, file_content)
      UI.success(target_path)
    end

    def ignore_param?(function_name: nil, param_name: nil)
      option_set = @action_options_to_ignore[function_name.to_s]
      unless option_set
        return false
      end

      return option_set.include?(param_name.to_s)
    end

    def process_action(action: nil)
      unless action.available_options
        return nil
      end
      options = action.available_options

      action_name = action.action_name
      keys = []
      key_descriptions = []
      key_default_values = []
      key_optionality_values = []
      key_type_overrides = []

      if options.kind_of? Array
        options.each do |current|
          next unless current.kind_of? FastlaneCore::ConfigItem

          if ignore_param?(function_name: action_name, param_name: current.key)
            next
          end

          keys << current.key.to_s
          key_descriptions << current.description
          key_default_values << current.default_value
          key_optionality_values << current.optional
          key_type_overrides << current.data_type
        end
      end
      action_return_type = action.return_type

      if self.tools_with_option_file.include?(action_name.to_s)
        tool_swift_function = ToolSwiftFunction.new(
          action_name: action_name,
          keys: keys,
          key_descriptions: key_descriptions,
          key_default_values: key_default_values,
          key_optionality_values: key_optionality_values,
          key_type_overrides: key_type_overrides,
          return_type: action_return_type
        )
        generate_tool_protocol(tool_swift_function: tool_swift_function)
        return tool_swift_function
      else
        return SwiftFunction.new(
          action_name: action_name,
          keys: keys,
          key_descriptions: key_descriptions,
          key_default_values: key_default_values,
          key_optionality_values: key_optionality_values,
          key_type_overrides: key_type_overrides,
          return_type: action_return_type
        )
      end
    end
  end
end
