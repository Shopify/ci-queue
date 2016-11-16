module OutputHelpers
  private

  def decolorize_output(output)
    output.gsub(/\e\[\d+m/, '')
  end

  def strip_heredoc(heredoc)
    indent = heredoc.scan(/^[ \t]*(?=\S)/).min.size || 0
    heredoc.gsub(/^[ \t]{#{indent}}/, '')
  end

  def freeze_timing(output)
    output.gsub(/\s\d+\.\d+s\s/, ' X.XXs ')
  end
end
