# frozen_string_literal: true

class UserEmailValidator < ActiveModel::Validator
  def validate(user)
    return if user.valid_invitation? || user.email.blank?

    # yttrx: the same pre-emptive lookup as in RegistrationHelper#ip_blocked?,
    # for the signal that one can't see. That hook fires before an email
    # address exists; this is the first point where the domain is known, so
    # it's where welcomebot gets the chance to classify the domain and
    # register an EmailDomainBlock before the check below runs.
    #
    # Guarded on new_record? so it fires at signup only, not on every later
    # email change. Best-effort: see app/lib/welcomebot_reputation.rb.
    if user.new_record?
      WelcomebotReputation.check(ip: user.sign_up_ip.to_s, email: user.email, source: 'sign_up')
    end

    user.errors.add(:email, :blocked) if blocked_email_provider?(user.email, user.sign_up_ip)
    user.errors.add(:email, :taken) if blocked_canonical_email?(user.email)
  end

  private

  def blocked_email_provider?(email, ip)
    disallowed_through_email_domain_block?(email, ip) || disallowed_through_configuration?(email) || not_allowed_through_configuration?(email)
  end

  def blocked_canonical_email?(email)
    CanonicalEmailBlock.block?(email)
  end

  def disallowed_through_email_domain_block?(email, ip)
    EmailDomainBlock.block?(email, attempt_ip: ip)
  end

  def not_allowed_through_configuration?(email)
    return false if Rails.configuration.x.email_domains_allowlist.blank?

    domains = Rails.configuration.x.email_domains_allowlist.gsub('.', '\.')
    regexp  = Regexp.new("@(.+\\.)?(#{domains})$", true)

    email !~ regexp
  end

  def disallowed_through_configuration?(email)
    return false if Rails.configuration.x.email_domains_denylist.blank?

    domains = Rails.configuration.x.email_domains_denylist.gsub('.', '\.')
    regexp  = Regexp.new("@(.+\\.)?(#{domains})", true)

    regexp.match?(email)
  end
end
