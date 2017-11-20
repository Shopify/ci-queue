module OutputHelpers
  private

  def decolorize_output(output)
    output.to_s.gsub(/\e\[\d+m/, '')
  end

  def strip_heredoc(heredoc)
    indent = heredoc.scan(/^[ \t]*(?=\S)/).min.size || 0
    heredoc.gsub(/^[ \t]{#{indent}}/, '')
  end

  def freeze_timing(output)
    output.to_s.gsub(/\s\d+\.\d+s/, ' X.XXs')
  end
end
