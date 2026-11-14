package de.aklozyp.moddexbackend.api.server.service

/**
 * The one-time local bootstrap proof for the initial administrator setup is
 * missing, wrong, expired, or already used. The message names the problem and
 * a safe next action; it never contains the proof itself.
 */
class SetupBootstrapProofInvalidException(message: String) : RuntimeException(message)
