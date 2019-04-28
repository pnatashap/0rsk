# frozen_string_literal: true

# Copyright (c) 2019 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require_relative 'rsk'
require_relative 'plan'
require_relative 'tasks'
require_relative 'project'

# Plans.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2019 Yegor Bugayenko
# License:: MIT
class Rsk::Plans
  def initialize(pgsql, project)
    @pgsql = pgsql
    @project = project
  end

  # Promote plans into tasks, if their schedules requre.
  def promote
    tasks = Rsk::Tasks.new(@pgsql, Rsk::Project.new(@pgsql, @project).login)
    @pgsql.exec('SELECT * FROM plan WHERE project = $1').each do |r|
      # next unless expired?(r['promoted'] ? Time.parse(r['promoted']) : Time.now, r['schedule'])
      tasks.add(r['id'].to_i)
    end
  end

  def add(text)
    raise Rsk::Urror, 'Plan text can\'t be empty' if text.empty?
    @pgsql.exec(
      'INSERT INTO plan (project, text) VALUES ($1, $2) RETURNING id',
      [@project, text]
    )[0]['id'].to_i
  end

  def exists?(id)
    !@pgsql.exec(
      'SELECT * FROM plan WHERE project = $1 AND id = $2',
      [@project, id]
    ).empty?
  end

  def get(id)
    require_relative 'plan'
    Rsk::Plan.new(@pgsql, id)
  end

  def fetch(query: '', limit: 10, offset: 0)
    rows = @pgsql.exec(
      [
        'SELECT * FROM plan',
        'JOIN plans ON plans.plan = plan.id',
        'WHERE project = $1',
        'AND',
        query.is_a?(Integer) ? "plans.triple = #{query}" : 'text LIKE $2',
        'OFFSET $3 LIMIT $4'
      ].join(' '),
      [@project, "%#{query}%", offset, limit]
    )
    rows.map do |r|
      {
        label: "P#{r['id']}: #{r['text']}",
        value: r['text'],
        fields: {
          pid: r['id'].to_i,
          schedule: r['schedule']
        }
      }
    end
  end

  private

  def deadline(plan)
    schedule = plan.schedule.strip.downcase
    if schedule == 'weekly'
      Time.now + 3 * 24 * 60 * 60
    elsif schedule == 'biweekly'
      Time.now + 7 * 24 * 60 * 60
    elsif schedule == 'monthly'
      Time.now + 14 * 24 * 60 * 60
    elsif /^[0-9]{2}-[0-9]{2}-[0-9]{4}$/.match?(schedule)
      time = Time.parse(schedule)
      time < Time.now ? Time.now + 60 * 60 : time
    else
      Time.now + 60 * 60
    end
  end
end
