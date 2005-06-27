class SpamFilter < Plugin
  def init_plugin
    begin
      @mail_store.get_mailbox("spam")
    rescue NoMailboxError
      mailbox = SpamMailbox.new(@mail_store, "spam", "flags" => "")
      mailbox.save
      @logger.info("mailbox created: spam")
    end
  end

  def filter(mail)
    IO.popen("bsfilter", "w") do |bsfilter|
      bsfilter.write(mail.raw_data)
    end
    if $?.exitstatus == 0
      return @mail_store.get_mailbox("spam")
    else
      return nil
    end
  end
end
