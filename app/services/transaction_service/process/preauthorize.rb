# coding: utf-8
module TransactionService::Process
  Gateway = TransactionService::Gateway
  Worker = TransactionService::Worker
  ProcessStatus = TransactionService::DataTypes::ProcessStatus
  DataTypes = TransactionService::DataTypes::Transaction

  class Preauthorize

    TxStore = TransactionService::Store::Transaction

    def create(tx:, gateway_fields:, gateway_adapter:, force_sync:)
      Transition.transition_to(tx[:id], :initiated)

      if use_async?(force_sync, gateway_adapter)
        proc_token = Worker.enqueue_preauthorize_op(
          community_id: tx[:community_id],
          transaction_id: tx[:id],
          op_name: :do_create,
          op_input: [tx, gateway_fields])

        proc_status_response(proc_token)
      else
        do_create(tx, gateway_fields)
      end
    end

    def do_create(tx, gateway_fields)
      gateway_adapter = TransactionService::Transaction.gateway_adapter(tx[:payment_gateway])

      completion = gateway_adapter.create_payment(
        tx: tx,
        gateway_fields: gateway_fields,
        force_sync: true)

      Gateway.unwrap_completion(completion) do
        finalize_create(tx: tx, gateway_adapter: gateway_adapter, force_sync: true)
      end
    end

    def finalize_create(tx:, gateway_adapter:, force_sync:)
      ensure_can_execute!(tx: tx, allowed_states: [:initiated, :preauthorized])

      if use_async?(force_sync, gateway_adapter)
        proc_token = Worker.enqueue_preauthorize_op(
          community_id: tx[:community_id],
          transaction_id: tx[:id],
          op_name: :do_finalize_create,
          op_input: [tx[:id], tx[:community_id]])

        proc_status_response(proc_token)
      else
        do_finalize_create(tx[:id], tx[:community_id])
      end
    end

    def do_finalize_create(transaction_id, community_id)
      tx = TxStore.get_in_community(community_id: community_id, transaction_id: transaction_id)
      gateway_adapter = TransactionService::Transaction.gateway_adapter(tx[:payment_gateway])

      res =
        if tx[:current_state] == :preauthorized
          Result::Success.new()
        else
          booking_res =
            if tx[:availability] != :booking
              Result::Success.new()
            else
              end_on = tx[:booking][:end_on]
              end_adjusted = tx[:unit_type] == :day ? end_on + 1.days : end_on

              HarmonyClient.post(
                :initiate_booking,
                body: {
                  marketplaceId: tx[:community_uuid],
                  refId: tx[:listing_uuid],
                  customerId: UUIDUtils.base64_to_uuid(tx[:starter_id]),
                  initialStatus: :paid,
                  start: tx[:booking][:start_on],
                  end: end_adjusted
                },
                opts: {
                  max_attempts: 3
                }).on_error { |error_msg, data|
                logger.error("Failed to initiate booking", :failed_initiate_booking, tx.slice(:community_id, :id).merge(error_msg: error_msg))

                void_res = gateway_adapter.reject_payment(tx: tx, reason: "")[:response]

                void_res.on_success {
                  logger.info("Payment voided after failed transaction", :void_payment, tx.slice(:community_id, :id))
                }.on_error { |payment_error_msg, payment_data|
                  logger.error("Failed to void payment after failed booking", :failed_void_payment, tx.slice(:community_id, :id).merge(error_msg: payment_error_msg))
                }
              }.on_success { |data|
                response_body = data[:body]
                booking = response_body[:data]

                TxStore.update_booking_uuid(
                  community_id: tx[:community_id],
                  transaction_id: tx[:id],
                  booking_uuid: booking[:id]
                )
              }
            end

          booking_res.on_success {
            Transition.transition_to(tx[:id], :preauthorized)
          }.rescue { |error_msg, data|
            #
            # The operation output is saved as YAML in database.
            # Serializing/deserializing the Exception object causes issues,
            # so we'll just convert the error to string
            #

            data[:error] = data[:error].to_s if data[:error].present?

            Result::Error.new(error_msg, data)
          }
        end

      res.and_then {
        Result::Success.new(DataTypes.create_transaction_response(tx))
      }
    end

    def reject(tx:, message:, sender_id:, gateway_adapter:)
      res = Gateway.unwrap_completion(
        gateway_adapter.reject_payment(tx: tx, reason: "")) do

        finalize_reject(tx: tx, gateway_adapter: gateway_adapter)
      end

      if res[:success] && message.present?
        send_message(tx, message, sender_id)
      end

      res
    end

    def finalize_reject(tx:, gateway_adapter:, metadata: nil)
      ensure_can_execute!(tx: tx, allowed_states: [:rejected, :preauthorized, :pending_ext])

      if tx[:current_state] == :rejected
        Result::Success.new()
      else
        Transition.transition_to(tx[:id], :rejected, metadata)

        if tx[:availability] != :booking
          Result::Success.new()
        else
          HarmonyClient.post(
            :reject_booking,
            params: {
              id: tx[:booking_uuid]
            },
            body: {
              actorId: UUIDUtils.base64_to_uuid(tx[:listing_author_id]),
              reason: "rejected" # TODO Proper reason
            },
            opts: {
              max_attempts: 3
            }).on_error { |error_msg, data|

            logger.error("Failed to reject booking",
                         :failed_reject_booking,
                         tx.slice(:community_id, :id).merge(error_msg: error_msg))
          }
        end
      end
    end

    def complete_preauthorization(tx:, message:, sender_id:, gateway_adapter:)
      res = Gateway.unwrap_completion(
        gateway_adapter.complete_preauthorization(tx: tx)) do

        finalize_complete_preauthorization(tx: tx, gateway_adapter: gateway_adapter)
      end

      if res[:success] && message.present?
        send_message(tx, message, sender_id)
      end

      res
    end

    def finalize_complete_preauthorization(tx:, gateway_adapter:)
      ensure_can_execute!(tx: tx, allowed_states: [:preauthorized, :pending_ext, :paid])

      if tx[:current_state] == :paid
        Result::Success.new()
      else
        Transition.transition_to(tx[:id], :paid)

        if tx[:availability] != :booking
          Result::Success.new()
        else
          HarmonyClient.post(
            :accept_booking,
            params: {
              id: tx[:booking_uuid]
            },
            body: {
              actorId: UUIDUtils.base64_to_uuid(tx[:listing_author_id]),
              reason: "provicer accepted"
            },
            opts: {
              max_attempts: 3
            }).on_error { |error_msg, data|

            logger.error("Failed to accept booking",
                         :failed_accept_booking,
                         tx.slice(:community_id, :id).merge(error_msg: error_msg))
          }
        end
      end
    end

    def complete(tx:, message:, sender_id:, gateway_adapter:)
      Transition.transition_to(tx[:id], :confirmed)
      TxStore.mark_as_unseen_by_other(community_id: tx[:community_id],
                                      transaction_id: tx[:id],
                                      person_id: tx[:listing_author_id])

      if message.present?
        send_message(tx, message, sender_id)
      end

      Result::Success.new({result: true})
    end

    def cancel(tx:, message:, sender_id:, gateway_adapter:)
      Transition.transition_to(tx[:id], :canceled)
      TxStore.mark_as_unseen_by_other(community_id: tx[:community_id],
                                      transaction_id: tx[:id],
                                      person_id: tx[:listing_author_id])

      if message.present?
        send_message(tx, message, sender_id)
      end

      Result::Success.new({result: true})
    end


    private

    def send_message(tx, message, sender_id)
      TxStore.add_message(community_id: tx[:community_id],
                          transaction_id: tx[:id],
                          message: message,
                          sender_id: sender_id)
    end

    def proc_status_response(proc_token)
      Result::Success.new(
        ProcessStatus.create_process_status({
                                              process_token: proc_token[:process_token],
                                              completed: proc_token[:op_completed],
                                              result: proc_token[:op_output]}))
    end

    def use_async?(force_sync, gw_adapter)
      !force_sync && gw_adapter.allow_async?
    end

    def logger
      @logger ||= SharetribeLogger.new(:preauthorize_process)
    end

    def ensure_can_execute!(tx:, allowed_states:)
      tx_state = tx[:current_state]

      unless allowed_states.include?(tx_state)
        rase TransactionService::Transaction::IllegalTransactionStateException.new(
               "Transaction was in illegal state, expected state: [#{allowed_states.join(',')}], actual state: #{tx_state}")
      end
    end
  end
end
