defmodule KafkaEx.New.Adapter do
  @moduledoc false
  # this should not be considered part of the public API

  # Code that converts old-style KafkaEx request structures to and from Kayrock
  # structures

  # No new code should rely on this code.  This should only be around to support
  # the compatibility mode during transition to the new API.

  alias KafkaEx.Protocol.ApiVersions.ApiVersion
  alias KafkaEx.Protocol.CreateTopics.Response, as: CreateTopicsResponse
  alias KafkaEx.Protocol.CreateTopics.TopicError, as: CreateTopicError
  alias KafkaEx.Protocol.DeleteTopics.Response, as: DeleteTopicsResponse
  alias KafkaEx.Protocol.DeleteTopics.TopicError, as: DeleteTopicError
  alias KafkaEx.Protocol.Heartbeat.Response, as: HeartbeatResponse
  alias KafkaEx.Protocol.Metadata.Broker
  alias KafkaEx.Protocol.Metadata.TopicMetadata
  alias KafkaEx.Protocol.Metadata.PartitionMetadata
  alias KafkaEx.Protocol.Metadata.Response, as: MetadataResponse
  alias KafkaEx.Protocol.JoinGroup.Response, as: JoinGroupResponse
  alias KafkaEx.Protocol.LeaveGroup.Response, as: LeaveGroupResponse
  alias KafkaEx.Protocol.Offset, as: Offset
  alias KafkaEx.Protocol.Offset.Response, as: OffsetResponse
  alias KafkaEx.Protocol.OffsetFetch.Response, as: OffsetFetchResponse
  alias KafkaEx.Protocol.OffsetCommit.Response, as: OffsetCommitResponse
  alias KafkaEx.Protocol.SyncGroup.Response, as: SyncGroupResponse
  alias KafkaEx.Protocol.Fetch.Response, as: FetchResponse
  alias KafkaEx.Protocol.Fetch.Message, as: FetchMessage

  alias Kayrock.MessageSet
  alias Kayrock.MessageSet.Message

  def list_offsets_request(topic, partition, time) do
    time = Offset.parse_time(time)

    partition_request = %{partition: partition, timestamp: time}

    %Kayrock.ListOffsets.V1.Request{
      replica_id: -1,
      topics: [%{topic: topic, partitions: [partition_request]}]
    }
  end

  def list_offsets_response(api_response) do
    Enum.map(api_response.responses, fn r ->
      %OffsetResponse{
        topic: r.topic,
        partition_offsets:
          Enum.map(r.partition_responses, fn p ->
            %{
              error_code: Kayrock.ErrorCode.code_to_atom(p.error_code),
              offset: [p.offset],
              partition: p.partition
            }
          end)
      }
    end)
  end

  def produce_request(request) do
    topic = request.topic
    partition = request.partition

    message_set = %MessageSet{
      messages:
        Enum.map(
          request.messages,
          fn msg ->
            %Message{
              key: msg.key,
              value: msg.value,
              compression: request.compression
            }
          end
        )
    }

    request = %Kayrock.Produce.V0.Request{
      acks: request.required_acks,
      timeout: request.timeout,
      topic_data: [
        %{
          topic: request.topic,
          data: [
            %{partition: request.partition, record_set: message_set}
          ]
        }
      ]
    }

    {request, topic, partition}
  end

  def produce_response(%Kayrock.Produce.V0.Response{
        responses: [
          %{
            partition_responses: [
              %{base_offset: base_offset, error_code: 0}
            ]
          }
        ]
      }) do
    base_offset
  end

  def metadata_response(cluster_metadata) do
    brokers =
      cluster_metadata.brokers
      |> Enum.map(fn {node_id, broker} ->
        kayrock_broker_to_kafka_ex_broker(
          {node_id, broker},
          node_id == cluster_metadata.controller_id
        )
      end)

    topics =
      cluster_metadata.topics
      |> Enum.map(&kayrock_topic_to_kafka_ex_topic_metadata/1)

    %MetadataResponse{
      brokers: brokers,
      topic_metadatas: topics
    }
  end

  def fetch_request(fetch_request) do
    {%Kayrock.Fetch.V0.Request{
       max_wait_time: fetch_request.wait_time,
       min_bytes: fetch_request.min_bytes,
       replica_id: -1,
       topics: [
         %{
           topic: fetch_request.topic,
           partitions: [
             %{
               partition: fetch_request.partition,
               fetch_offset: fetch_request.offset,
               max_bytes: fetch_request.max_bytes
             }
           ]
         }
       ]
     }, fetch_request.topic, fetch_request.partition}
  end

  def fetch_response(fetch_response) do
    [topic_response | _] = fetch_response.responses
    [partition_response | _] = topic_response.partition_responses

    {message_set, last_offset} =
      kayrock_message_set_to_kafka_ex(partition_response.record_set)

    {[
       %FetchResponse{
         topic: topic_response.topic,
         partitions: [
           %{
             partition: partition_response.partition_header.partition,
             error_code:
               KafkaEx.Protocol.error(
                 partition_response.partition_header.error_code
               ),
             hw_mark_offset: partition_response.partition_header.high_watermark,
             message_set: message_set,
             last_offset:
               last_offset || partition_response.partition_header.high_watermark
           }
         ]
       }
     ], last_offset}
  end

  def join_group_request(join_group_request) do
    request = %Kayrock.JoinGroup.V0.Request{
      group_id: join_group_request.group_name,
      member_id: join_group_request.member_id,
      session_timeout: join_group_request.session_timeout,
      protocol_type: "consumer",
      group_protocols: [
        %{
          protocol_name: "assign",
          protocol_metadata: %Kayrock.GroupProtocolMetadata{
            topics: join_group_request.topics
          }
        }
      ]
    }

    {request, request.group_id}
  end

  def join_group_response(%Kayrock.JoinGroup.V0.Response{
        error_code: error_code,
        generation_id: generation_id,
        leader_id: leader_id,
        member_id: member_id,
        members: members
      }) do
    %JoinGroupResponse{
      error_code: Kayrock.ErrorCode.code_to_atom(error_code),
      generation_id: generation_id,
      leader_id: leader_id,
      member_id: member_id,
      members: Enum.map(members, fn m -> m.member_id end)
    }
  end

  def sync_group_request(request) do
    {%Kayrock.SyncGroup.V0.Request{
       group_id: request.group_name,
       generation_id: request.generation_id,
       member_id: request.member_id,
       group_assignment:
         Enum.map(request.assignments, &kafka_ex_group_assignment_to_kayrock/1)
     }, request.group_name}
  end

  def sync_group_response(%Kayrock.SyncGroup.V0.Response{
        error_code: error_code,
        member_assignment: %Kayrock.MemberAssignment{
          partition_assignments: partition_assignments
        }
      }) do
    %SyncGroupResponse{
      error_code: Kayrock.ErrorCode.code_to_atom(error_code),
      assignments:
        Enum.map(partition_assignments, fn p -> {p.topic, p.partitions} end)
    }
  end

  def leave_group_request(request) do
    {%Kayrock.LeaveGroup.V0.Request{
       group_id: request.group_name,
       member_id: request.member_id
     }, request.group_name}
  end

  def leave_group_response(%Kayrock.LeaveGroup.V0.Response{
        error_code: error_code
      }) do
    %LeaveGroupResponse{error_code: Kayrock.ErrorCode.code_to_atom(error_code)}
  end

  def heartbeat_request(request) do
    {%Kayrock.Heartbeat.V0.Request{
       group_id: request.group_name,
       member_id: request.member_id,
       generation_id: request.generation_id
     }, request.group_name}
  end

  def heartbeat_response(%Kayrock.Heartbeat.V0.Response{error_code: error_code}) do
    %HeartbeatResponse{error_code: Kayrock.ErrorCode.code_to_atom(error_code)}
  end

  def create_topics_request(requests, timeout) do
    %Kayrock.CreateTopics.V0.Request{
      timeout: timeout,
      create_topic_requests:
        Enum.map(requests, &kafka_ex_to_kayrock_create_topics/1)
    }
  end

  def create_topics_response(%Kayrock.CreateTopics.V0.Response{
        topic_errors: topic_errors
      }) do
    %CreateTopicsResponse{
      topic_errors:
        Enum.map(topic_errors, fn e ->
          %CreateTopicError{
            topic_name: e.topic,
            error_code: Kayrock.ErrorCode.code_to_atom(e.error_code)
          }
        end)
    }
  end

  def delete_topics_request(topics, timeout) do
    %Kayrock.DeleteTopics.V0.Request{
      topics: topics,
      timeout: timeout
    }
  end

  def delete_topics_response(%Kayrock.DeleteTopics.V0.Response{
        topic_error_codes: topic_error_codes
      }) do
    %DeleteTopicsResponse{
      topic_errors:
        Enum.map(topic_error_codes, fn ec ->
          %DeleteTopicError{
            topic_name: ec.topic,
            error_code: Kayrock.ErrorCode.code_to_atom(ec.error_code)
          }
        end)
    }
  end

  def api_versions(versions_map) do
    api_versions =
      versions_map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {api_key, {min_version, max_version}} ->
        %ApiVersion{
          api_key: api_key,
          min_version: min_version,
          max_version: max_version
        }
      end)

    %KafkaEx.Protocol.ApiVersions.Response{
      api_versions: api_versions,
      error_code: :no_error,
      throttle_time_ms: 0
    }
  end

  def offset_fetch_request(request, client_consumer_group) do
    consumer_group = request.consumer_group || client_consumer_group

    {%Kayrock.OffsetFetch.V0.Request{
       group_id: consumer_group,
       topics: [
         %{topic: request.topic, partitions: [%{partition: request.partition}]}
       ]
     }, consumer_group}
  end

  def offset_fetch_response(%Kayrock.OffsetFetch.V0.Response{
        responses: [
          %{
            topic: topic,
            partition_responses: [
              %{
                partition: partition,
                offset: offset,
                metadata: metadata,
                error_code: error_code
              }
            ]
          }
        ]
      }) do
    [
      %OffsetFetchResponse{
        topic: topic,
        partitions: [
          %{
            partition: partition,
            offset: offset,
            metadata: metadata,
            error_code: Kayrock.ErrorCode.code_to_atom(error_code)
          }
        ]
      }
    ]
  end

  def offset_commit_request(request, client_consumer_group) do
    consumer_group = request.consumer_group || client_consumer_group

    {%Kayrock.OffsetCommit.V0.Request{
       group_id: consumer_group,
       topics: [
         %{
           topic: request.topic,
           partitions: [
             %{
               partition: request.partition,
               offset: request.offset,
               metadata: ""
             }
           ]
         }
       ]
     }, consumer_group}
  end

  def offset_commit_response(%Kayrock.OffsetCommit.V0.Response{
        responses: [
          %{
            topic: topic,
            partition_responses: [
              %{partition: partition}
            ]
          }
        ]
      }) do
    # NOTE kafkaex protocol ignores error code here
    [
      %OffsetCommitResponse{
        topic: topic,
        partitions: [partition]
      }
    ]
  end

  defp kafka_ex_to_kayrock_create_topics(request) do
    %{
      topic: request.topic,
      num_partitions: request.num_partitions,
      replication_factor: request.replication_factor,
      replica_assignment:
        Enum.map(request.replica_assignment, &Map.from_struct/1),
      config_entries:
        Enum.map(request.config_entries, fn ce ->
          %{config_name: ce.config_name, config_value: ce.config_value}
        end)
    }
  end

  defp kafka_ex_group_assignment_to_kayrock({member_id, member_assignments}) do
    %{
      member_id: member_id,
      member_assignment: %Kayrock.MemberAssignment{
        version: 0,
        partition_assignments:
          Enum.map(member_assignments, fn {topic, partitions} ->
            %Kayrock.MemberAssignment.PartitionAssignment{
              topic: topic,
              partitions: partitions
            }
          end),
        user_data: ""
      }
    }
  end

  defp kayrock_message_set_to_kafka_ex(%Kayrock.RecordBatch{} = record_batch) do
    messages =
      Enum.map(record_batch.records, fn record ->
        %FetchMessage{
          attributes: record.attributes,
          crc: nil,
          key: record.key,
          value: record.value,
          offset: record.offset
        }
      end)

    case messages do
      [] ->
        {messages, nil}

      _ ->
        last_offset_message = Enum.max_by(messages, fn m -> m.offset end)
        {messages, last_offset_message.offset}
    end
  end

  defp kayrock_message_set_to_kafka_ex(%Kayrock.MessageSet{} = message_set) do
    messages =
      Enum.map(message_set.messages, fn message ->
        %FetchMessage{
          attributes: message.attributes,
          crc: message.crc,
          key: message.key,
          value: message.value,
          offset: message.offset
        }
      end)

    case messages do
      [] ->
        {messages, nil}

      _ ->
        last_offset_message = Enum.max_by(messages, fn m -> m.offset end)
        {messages, last_offset_message.offset}
    end
  end

  defp kayrock_broker_to_kafka_ex_broker({node_id, broker}, is_controller) do
    %Broker{
      node_id: node_id,
      host: broker.host,
      port: broker.port,
      socket: broker.socket,
      is_controller: is_controller
    }
  end

  defp kayrock_topic_to_kafka_ex_topic_metadata({topic_name, topic}) do
    %TopicMetadata{
      topic: topic_name,
      is_internal: topic.is_internal,
      partition_metadatas:
        Enum.map(
          topic.partitions,
          &kayrock_partition_to_kafka_ex_partition_metadata/1
        )
    }
  end

  defp kayrock_partition_to_kafka_ex_partition_metadata(partition) do
    %PartitionMetadata{
      partition_id: partition.partition_id,
      leader: partition.leader,
      replicas: partition.replicas,
      isrs: partition.isr
    }
  end
end
