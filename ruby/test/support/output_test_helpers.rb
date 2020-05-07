# frozen_string_literal: true
module OutputTestHelpers
  PROJECT_ROOT_PATH = File.expand_path('../../../', __FILE__)
  private

  def strip_blank_lines(output)
    output.lines.map { |l| l.strip.empty? ? "\n" : l }.join
  end

  def decolorize_output(output)
    output.to_s.gsub(/\e\[\d+m/, '')
  end

  def strip_heredoc(heredoc)
    indent = heredoc.scan(/^[ \t]*(?=\S)/).min.size || 0
    heredoc.gsub(/^[ \t]{#{indent}}/, '')
  end

  def freeze_timing(output)
    output.to_s.gsub(/\d+\.\d+s/, 'X.XXs').gsub(/ \d+\.\d+ seconds /, ' X.XXXXX seconds ')
  end

  def freeze_seed(output)
    output.to_s.gsub(/\-\-seed \d+/, '--seed XXXXX')
  end

  def rewrite_paths(output)
    output.to_s.gsub(PROJECT_ROOT_PATH, '.')
  end

  def freeze_xml_timing(output)
    output.gsub(/time="[\d\-\.e]+"/, 'time="X.XX"')
  end

  def normalize(output)
    freeze_timing(decolorize_output(output))
  end
end
