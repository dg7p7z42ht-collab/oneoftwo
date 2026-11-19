const OneOfTwoAuth = (() => {
  let client;

  function getClient() {
    client ??= window.supabase.createClient(
      'https://lnbrqcklgndbizlhkdef.supabase.co',
      'sb_publishable_EzhbUdb-HgoZ6hYtuvLfgQ_sY2fvRXW',
      { auth: { flowType: 'implicit', detectSessionInUrl: false } }
    );
    return client;
  }

  function confirmationUrl() {
    return new URL('auth-confirm.html', window.location.href).href;
  }

  function errorMessage(error, fallback) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Email or password is incorrect.';
      case 'email_not_confirmed':
        return 'Confirm your email before signing in.';
      case 'weak_password':
        return 'Choose a stronger password that meets the password requirements.';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Too many attempts. Please try again later.';
    }
    if (error.status === 429) return 'Too many attempts. Please try again later.';
    if (error.name === 'AuthRetryableFetchError' || error instanceof TypeError) {
      return 'Unable to connect. Check your connection and try again.';
    }
    return fallback;
  }

  async function resendConfirmation(email) {
    return getClient().auth.resend({
      type: 'signup',
      email,
      options: { emailRedirectTo: confirmationUrl() }
    });
  }

  return { getClient, confirmationUrl, errorMessage, resendConfirmation };
})();
