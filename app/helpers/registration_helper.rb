# frozen_string_literal: true

module RegistrationHelper
  extend ActiveSupport::Concern

  # yttrx: reputation: :async lets a caller that is only RENDERING the signup
  # form ask welcomebot to classify and block the address without waiting for
  # the answer. Every other caller here is a real signup attempt, so the
  # default stays blocking.
  def allowed_registration?(remote_ip, invite, reputation: :blocking)
    !Rails.configuration.x.single_user_mode && !omniauth_only? && (registrations_open? || invite&.valid_for_use?) && !ip_blocked?(remote_ip, reputation: reputation)
  end

  def registrations_open?
    Setting.registrations_mode != 'none'
  end

  def omniauth_only?
    ENV['OMNIAUTH_ONLY'] == 'true'
  end

  def ip_blocked?(remote_ip, reputation: :blocking)
    # yttrx: give welcomebot a chance to classify this address and register a
    # block for it BEFORE we look one up, so a range nobody has signed up from
    # yet can still be rejected here. Best-effort and advisory — if welcomebot
    # is unconfigured, slow or down this is a no-op and the lookup below
    # behaves exactly as it does upstream. See app/lib/welcomebot_reputation.rb.
    #
    # On the form render (:async) we fire the query and don't wait: the block
    # still gets installed, but the page doesn't pay the ~700ms round trip.
    # By the time the form is submitted the answer is cached, so the blocking
    # query on that path is cheap — and correct even if the warm-up never
    # finished.
    WelcomebotReputation.check(ip: remote_ip.to_s, source: 'registration',
                               async: reputation == :async)

    IpBlock.severity_sign_up_block.containing(remote_ip.to_s).exists?
  end

  def terms_agreement_label
    if TermsOfService.live.exists?
      t('auth.user_agreement_html', privacy_policy_path: privacy_policy_path, terms_of_service_path: terms_of_service_path)
    else
      t('auth.user_privacy_agreement_html', privacy_policy_path: privacy_policy_path)
    end
  end
end
