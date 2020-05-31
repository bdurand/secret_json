# frozen_string_literal: true

require "securerandom"
require "openssl"
require "base64"

# Encyption helper for encrypting and decrypting values using AES-256-GCM and returning
# as Base64 encoded strings. The encrypted values also include a prefix that can be used
# to detect if a string is an encrypted value.
class SecretKeys::Encryptor
  # format: <nonce:12>, <auth_tag:16>, <data:*>
  ENCODING_FORMAT = "a12 a16 a*"
  ENCRYPTED_PREFIX = "$AES$:"
  CIPHER = "aes-256-gcm"
  KDF_ITERATIONS = 20_000
  HASH_FUNC = "sha256"
  KEY_LENGTH = 32

  class << self
    # Create an instance from a secret and salt.
    # @param [String] password secret used to encrypt the data
    # @param [Integer] salt random salt for key derivation.
    # @return [SecretKeys::Encryptor] a new encryptor with key derived from password and salt
    def from_password(password, salt)
      raise ArgumentError, "Password must be present" if password.nil? || password.empty?
      raise ArgumentError, "Salt must be an integer" unless salt.is_a?(Integer)
      # Convert the salt to raw byte string
      salt_bytes = [salt.to_s(16)].pack("H*")
      derived_key = derive_key(password, salt: salt_bytes, length: KEY_LENGTH)

      new(derived_key)
    end

    # Detect of the value is a string that was encrypted by this library.
    def encrypted?(value)
      value.is_a?(String) && value.start_with?(ENCRYPTED_PREFIX) && value.size > ENCRYPTED_PREFIX.size
    end

    # Derive a key of given length from a password and salt value.
    def derive_key(password, salt:, length:, iterations: KDF_ITERATIONS, hash: HASH_FUNC)
      if defined?(OpenSSL::KDF)
        OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: iterations, length: length, hash: hash)
      else
        # Ruby 2.4 compatibility
        OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, length, hash)
      end
    end
  end

  # @param [String] raw_key the key directly passed into the encrypt/decrypt functions. This must be exactly {KEY_LENGTH} bytes long.
  def initialize(raw_key)
    raise ArgumentError, "key must be #{KEY_LENGTH} bytes long" unless raw_key.bytesize == KEY_LENGTH
    @derived_key = raw_key
  end

  # Encrypt a string with the encryption key. Encrypted values are also salted so
  # calling this function multiple times will result in different values. Only strings
  # can be encrypted. Any other object type will be return the value passed in.
  #
  # @param [String] str string to encrypt (assumes UTF-8)
  # @return [String] Base64 encoded encrypted string with all aes parameters
  def encrypt(str)
    return str unless str.is_a?(String)
    return "" if str == ""

    cipher = OpenSSL::Cipher.new(CIPHER).encrypt

    # Technically, this is a "bad" way to do things since we could theoretically
    # get a repeat nonce, compromising the algorithm. That said, it should be safe
    # from repeats as long as we don't use this key for more than 2^32 encryptions
    # so... rotate your keys/salt ever 4 billion encryption calls
    nonce = cipher.random_iv
    cipher.key = @derived_key
    cipher.auth_data = ""

    # Make sure the string is encoded as UTF-8. JSON/YAML only support string types
    # anyways, so if you passed in binary data, it was gonna fail anyways. This ensures
    # that we can easily decode the string later. If you have UTF-16 or something, deal with it.
    utf8_str = str.encode(Encoding::UTF_8)
    encrypted_data = cipher.update(utf8_str) + cipher.final
    auth_tag = cipher.auth_tag

    params = CipherParams.new(nonce, auth_tag, encrypted_data)

    encode_aes(params).prepend(ENCRYPTED_PREFIX)
  end

  # Decrypt a string with the encryption key. If the value is not a string or it was
  # not encrypted with the encryption key, the value itself will be returned.
  #
  # @param [String] encrypted_str Base64 encoded encrypted string with aes params (from {#encrypt})
  # @return [String] decrypted string value
  # @raise [OpenSSL::Cipher::CipherError] there is something wrong with the encoded data (usually incorrect key)
  def decrypt(encrypted_str)
    return encrypted_str unless self.class.encrypted?(encrypted_str)

    decrypt_str = encrypted_str[ENCRYPTED_PREFIX.length..-1]
    params = decode_aes(decrypt_str)

    cipher = OpenSSL::Cipher.new(CIPHER).decrypt

    cipher.key = @derived_key
    cipher.iv = params.nonce
    cipher.auth_tag = params.auth_tag
    cipher.auth_data = ""

    decoded_str = cipher.update(params.data) + cipher.final

    # force to utf-8 encoding. We already ensured this when we encoded in the first place
    decoded_str.force_encoding(Encoding::UTF_8)
  end

  def inspect
    "#<#{self.class.name}:0x#{object_id.to_s(16).rjust(16, "0")}>"
  end

  private

  # Basic struct to contain nonce, auth_tag, and data for passing around. Thought
  # it was better than just passing an Array with positional params.
  # @private
  CipherParams = Struct.new(:nonce, :auth_tag, :data)

  # Receive a cipher object (initialized with key) and data
  def encode_aes(params)
    encoded = params.values.pack(ENCODING_FORMAT)
    # encode base64 and get rid of trailing newline and unnecessary =
    Base64.encode64(encoded).chomp.tr("=", "")
  end

  # Passed in an aes encoded string and returns a cipher object
  def decode_aes(str)
    unpacked_data = Base64.decode64(str).unpack(ENCODING_FORMAT)
    # Splat the data array apart
    # nonce, auth_tag, encrypted_data = unpacked_data
    CipherParams.new(*unpacked_data)
  end
end
